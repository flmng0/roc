const std = @import("std");
const utils = @import("utils.zig");
const UpdateMode = utils.UpdateMode;
const mem = std.mem;
const math = std.math;

const expect = std.testing.expect;

const EqFn = *const fn (?[*]u8, ?[*]u8) callconv(.C) bool;
const CompareFn = *const fn (?[*]u8, ?[*]u8, ?[*]u8) callconv(.C) u8;
const Opaque = ?[*]u8;

const Inc = *const fn (?[*]u8) callconv(.C) void;
const IncN = *const fn (?[*]u8, usize) callconv(.C) void;
const Dec = *const fn (?[*]u8) callconv(.C) void;
const HasTagId = *const fn (u16, ?[*]u8) callconv(.C) extern struct { matched: bool, data: ?[*]u8 };

const SEAMLESS_SLICE_BIT: usize =
    @as(usize, @bitCast(@as(isize, std.math.minInt(isize))));

pub const RocList = extern struct {
    bytes: ?[*]u8,
    length: usize,
    // For normal lists, contains the capacity.
    // For seamless slices contains the pointer to the original allocation.
    // This pointer is to the first element of the original list.
    // Note we storing an allocation pointer, the pointer must be right shifted by one.
    capacity_or_alloc_ptr: usize,

    pub inline fn len(self: RocList) usize {
        return self.length;
    }

    pub fn getCapacity(self: RocList) usize {
        const list_capacity = self.capacity_or_alloc_ptr;
        const slice_capacity = self.length;
        const slice_mask = self.seamlessSliceMask();
        const capacity = (list_capacity & ~slice_mask) | (slice_capacity & slice_mask);
        return capacity;
    }

    pub fn isSeamlessSlice(self: RocList) bool {
        return @as(isize, @bitCast(self.capacity_or_alloc_ptr)) < 0;
    }

    // This returns all ones if the list is a seamless slice.
    // Otherwise, it returns all zeros.
    // This is done without branching for optimization purposes.
    pub fn seamlessSliceMask(self: RocList) usize {
        return @as(usize, @bitCast(@as(isize, @bitCast(self.capacity_or_alloc_ptr)) >> (@bitSizeOf(isize) - 1)));
    }

    pub fn isEmpty(self: RocList) bool {
        return self.len() == 0;
    }

    pub fn empty() RocList {
        return RocList{ .bytes = null, .length = 0, .capacity_or_alloc_ptr = 0 };
    }

    pub fn eql(self: RocList, other: RocList) bool {
        if (self.len() != other.len()) {
            return false;
        }

        // Their lengths are the same, and one is empty; they're both empty!
        if (self.isEmpty()) {
            return true;
        }

        var index: usize = 0;
        const self_bytes = self.bytes orelse unreachable;
        const other_bytes = other.bytes orelse unreachable;

        while (index < self.len()) {
            if (self_bytes[index] != other_bytes[index]) {
                return false;
            }

            index += 1;
        }

        return true;
    }

    pub fn fromSlice(comptime T: type, slice: []const T, elements_refcounted: bool) RocList {
        if (slice.len == 0) {
            return RocList.empty();
        }

        var list = allocate(@alignOf(T), slice.len, @sizeOf(T), elements_refcounted);

        if (slice.len > 0) {
            const dest = list.bytes orelse unreachable;
            const src = @as([*]const u8, @ptrCast(slice.ptr));
            const num_bytes = slice.len * @sizeOf(T);

            @memcpy(dest[0..num_bytes], src[0..num_bytes]);
        }

        return list;
    }

    // returns a pointer to the original allocation.
    // This pointer points to the first element of the allocation.
    // The pointer is to just after the refcount.
    // For big lists, it just returns their bytes pointer.
    // For seamless slices, it returns the pointer stored in capacity_or_alloc_ptr.
    pub fn getAllocationPtr(self: RocList) ?[*]u8 {
        const list_alloc_ptr = @intFromPtr(self.bytes);
        const slice_alloc_ptr = self.capacity_or_alloc_ptr << 1;
        const slice_mask = self.seamlessSliceMask();
        const alloc_ptr = (list_alloc_ptr & ~slice_mask) | (slice_alloc_ptr & slice_mask);
        return @as(?[*]u8, @ptrFromInt(alloc_ptr));
    }

    // This function is only valid if the list has refcounted elements.
    fn getAllocationElementCount(self: RocList) usize {
        if (self.isSeamlessSlice()) {
            // Seamless slices always refer to an underlying allocation.
            const alloc_ptr = self.getAllocationPtr() orelse unreachable;
            // - 1 is refcount.
            // - 2 is size on heap.
            const ptr = @as([*]usize, @ptrCast(@alignCast(alloc_ptr))) - 2;
            return ptr[0];
        } else {
            return self.length;
        }
    }

    // This needs to be called when creating seamless slices from unique list.
    // It will put the allocation size on the heap to enable the seamless slice to free the underlying allocation.
    fn setAllocationElementCount(self: RocList, elements_refcounted: bool) void {
        if (elements_refcounted) {
            // - 1 is refcount.
            // - 2 is size on heap.
            const ptr = @as([*]usize, @alignCast(@ptrCast(self.getAllocationPtr()))) - 2;
            ptr[0] = self.length;
        }
    }

    pub fn incref(self: RocList, amount: isize, elements_refcounted: bool) void {
        // If the list is unique and not a seamless slice, the length needs to be store on the heap if the elements are refcounted.
        if (elements_refcounted and self.isUnique() and !self.isSeamlessSlice()) {
            if (self.getAllocationPtr()) |source| {
                // - 1 is refcount.
                // - 2 is size on heap.
                const ptr = @as([*]usize, @alignCast(@ptrCast(source))) - 2;
                ptr[0] = self.length;
            }
        }
        utils.increfDataPtrC(self.getAllocationPtr(), amount);
    }

    pub fn decref(self: RocList, alignment: u32, element_width: usize, elements_refcounted: bool, dec: Dec) void {
        // If unique, decref will free the list. Before that happens, all elements must be decremented.
        if (elements_refcounted and self.isUnique()) {
            if (self.getAllocationPtr()) |source| {
                const count = self.getAllocationElementCount();

                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const element = source + i * element_width;
                    dec(element);
                }
            }
        }

        // We use the raw capacity to ensure we always decrement the refcount of seamless slices.
        utils.decref(self.getAllocationPtr(), self.capacity_or_alloc_ptr, alignment, elements_refcounted);
    }

    pub fn elements(self: RocList, comptime T: type) ?[*]T {
        return @as(?[*]T, @ptrCast(@alignCast(self.bytes)));
    }

    pub fn isUnique(self: RocList) bool {
        return self.refcountMachine() == utils.REFCOUNT_ONE;
    }

    fn refcountMachine(self: RocList) usize {
        if (self.getCapacity() == 0 and !self.isSeamlessSlice()) {
            // the zero-capacity is Clone, copying it will not leak memory
            return utils.REFCOUNT_ONE;
        }

        const ptr: [*]usize = @as([*]usize, @ptrCast(@alignCast(self.bytes)));
        return (ptr - 1)[0];
    }

    fn refcountHuman(self: RocList) usize {
        return self.refcountMachine() - utils.REFCOUNT_ONE + 1;
    }

    pub fn makeUniqueExtra(self: RocList, alignment: u32, element_width: usize, elements_refcounted: bool, dec: Dec, update_mode: UpdateMode) RocList {
        if (update_mode == .InPlace) {
            return self;
        } else {
            return self.makeUnique(alignment, element_width, elements_refcounted, dec);
        }
    }

    pub fn makeUnique(
        self: RocList,
        alignment: u32,
        element_width: usize,
        elements_refcounted: bool,
        inc: Inc,
        dec: Dec,
    ) RocList {
        if (self.isUnique()) {
            return self;
        }

        if (self.isEmpty()) {
            // Empty is not necessarily unique on it's own.
            // The list could have capacity and be shared.
            self.decref(alignment, element_width, elements_refcounted, dec);
            return RocList.empty();
        }

        // unfortunately, we have to clone
        var new_list = RocList.allocate(alignment, self.length, element_width, elements_refcounted);

        var old_bytes: [*]u8 = @as([*]u8, @ptrCast(self.bytes));
        var new_bytes: [*]u8 = @as([*]u8, @ptrCast(new_list.bytes));

        const number_of_bytes = self.len() * element_width;
        @memcpy(new_bytes[0..number_of_bytes], old_bytes[0..number_of_bytes]);

        // Increment refcount of all elements now in a new list.
        if (elements_refcounted) {
            var i: usize = 0;
            while (i < self.len()) : (i += 1) {
                inc(new_bytes + i * element_width);
            }
        }

        self.decref(alignment, element_width, elements_refcounted, dec);

        return new_list;
    }

    pub fn allocate(
        alignment: u32,
        length: usize,
        element_width: usize,
        elements_refcounted: bool,
    ) RocList {
        if (length == 0) {
            return empty();
        }

        const capacity = utils.calculateCapacity(0, length, element_width);
        const data_bytes = capacity * element_width;
        return RocList{
            .bytes = utils.allocateWithRefcount(data_bytes, alignment, elements_refcounted),
            .length = length,
            .capacity_or_alloc_ptr = capacity,
        };
    }

    pub fn allocateExact(
        alignment: u32,
        length: usize,
        element_width: usize,
        elements_refcounted: bool,
    ) RocList {
        if (length == 0) {
            return empty();
        }

        const data_bytes = length * element_width;
        return RocList{
            .bytes = utils.allocateWithRefcount(data_bytes, alignment, elements_refcounted),
            .length = length,
            .capacity_or_alloc_ptr = length,
        };
    }

    pub fn reallocate(
        self: RocList,
        alignment: u32,
        new_length: usize,
        element_width: usize,
        elements_refcounted: bool,
        inc: Inc,
    ) RocList {
        if (self.bytes) |source_ptr| {
            if (self.isUnique() and !self.isSeamlessSlice()) {
                const capacity = self.capacity_or_alloc_ptr;
                if (capacity >= new_length) {
                    return RocList{ .bytes = self.bytes, .length = new_length, .capacity_or_alloc_ptr = capacity };
                } else {
                    const new_capacity = utils.calculateCapacity(capacity, new_length, element_width);
                    const new_source = utils.unsafeReallocate(source_ptr, alignment, capacity, new_capacity, element_width, elements_refcounted);
                    return RocList{ .bytes = new_source, .length = new_length, .capacity_or_alloc_ptr = new_capacity };
                }
            }
            return self.reallocateFresh(alignment, new_length, element_width, elements_refcounted, inc);
        }
        return RocList.allocate(alignment, new_length, element_width, elements_refcounted);
    }

    /// reallocate by explicitly making a new allocation and copying elements over
    fn reallocateFresh(
        self: RocList,
        alignment: u32,
        new_length: usize,
        element_width: usize,
        elements_refcounted: bool,
        inc: Inc,
    ) RocList {
        const old_length = self.length;

        const result = RocList.allocate(alignment, new_length, element_width, elements_refcounted);

        if (self.bytes) |source_ptr| {
            // transfer the memory
            const dest_ptr = result.bytes orelse unreachable;

            @memcpy(dest_ptr[0..(old_length * element_width)], source_ptr[0..(old_length * element_width)]);
            @memset(dest_ptr[(old_length * element_width)..(new_length * element_width)], 0);

            // Increment refcount of all elements now in a new list.
            if (elements_refcounted) {
                var i: usize = 0;
                while (i < old_length) : (i += 1) {
                    inc(dest_ptr + i * element_width);
                }
            }
        }

        // Calls utils.decref directly to avoid decrementing the refcount of elements.
        utils.decref(self.getAllocationPtr(), self.capacity_or_alloc_ptr, alignment, elements_refcounted);

        return result;
    }
};

pub fn listIncref(list: RocList, amount: isize, elements_refcounted: bool) callconv(.C) void {
    list.incref(amount, elements_refcounted);
}

pub fn listDecref(list: RocList, alignment: u32, element_width: usize, elements_refcounted: bool, dec: Dec) callconv(.C) void {
    list.decref(alignment, element_width, elements_refcounted, dec);
}

const Caller0 = *const fn (?[*]u8, ?[*]u8) callconv(.C) void;
const Caller1 = *const fn (?[*]u8, ?[*]u8, ?[*]u8) callconv(.C) void;
const Caller2 = *const fn (?[*]u8, ?[*]u8, ?[*]u8, ?[*]u8) callconv(.C) void;
const Caller3 = *const fn (?[*]u8, ?[*]u8, ?[*]u8, ?[*]u8, ?[*]u8) callconv(.C) void;
const Caller4 = *const fn (?[*]u8, ?[*]u8, ?[*]u8, ?[*]u8, ?[*]u8, ?[*]u8) callconv(.C) void;

pub fn listMap(
    list: RocList,
    caller: Caller1,
    data: Opaque,
    inc_n_data: IncN,
    data_is_owned: bool,
    alignment: u32,
    old_element_width: usize,
    new_element_width: usize,
    new_elements_refcount: bool,
) callconv(.C) RocList {
    if (list.bytes) |source_ptr| {
        const size = list.len();
        var i: usize = 0;
        const output = RocList.allocate(alignment, size, new_element_width, new_elements_refcount);
        const target_ptr = output.bytes orelse unreachable;

        if (data_is_owned) {
            inc_n_data(data, size);
        }

        while (i < size) : (i += 1) {
            caller(data, source_ptr + (i * old_element_width), target_ptr + (i * new_element_width));
        }

        return output;
    } else {
        return RocList.empty();
    }
}

fn decrementTail(list: RocList, start_index: usize, element_width: usize, dec: Dec) void {
    if (list.bytes) |source| {
        var i = start_index;
        while (i < list.len()) : (i += 1) {
            const element = source + i * element_width;
            dec(element);
        }
    }
}

pub fn listMap2(
    list1: RocList,
    list2: RocList,
    caller: Caller2,
    data: Opaque,
    inc_n_data: IncN,
    data_is_owned: bool,
    alignment: u32,
    a_width: usize,
    b_width: usize,
    c_width: usize,
    dec_a: Dec,
    dec_b: Dec,
    c_elements_refcounted: bool,
) callconv(.C) RocList {
    const output_length = @min(list1.len(), list2.len());

    // if the lists don't have equal length, we must consume the remaining elements
    // In this case we consume by (recursively) decrementing the elements
    decrementTail(list1, output_length, a_width, dec_a);
    decrementTail(list2, output_length, b_width, dec_b);

    if (data_is_owned) {
        inc_n_data(data, output_length);
    }

    if (list1.bytes) |source_a| {
        if (list2.bytes) |source_b| {
            const output = RocList.allocate(alignment, output_length, c_width, c_elements_refcounted);
            const target_ptr = output.bytes orelse unreachable;

            var i: usize = 0;
            while (i < output_length) : (i += 1) {
                const element_a = source_a + i * a_width;
                const element_b = source_b + i * b_width;
                const target = target_ptr + i * c_width;
                caller(data, element_a, element_b, target);
            }

            return output;
        } else {
            return RocList.empty();
        }
    } else {
        return RocList.empty();
    }
}

pub fn listMap3(
    list1: RocList,
    list2: RocList,
    list3: RocList,
    caller: Caller3,
    data: Opaque,
    inc_n_data: IncN,
    data_is_owned: bool,
    alignment: u32,
    a_width: usize,
    b_width: usize,
    c_width: usize,
    d_width: usize,
    dec_a: Dec,
    dec_b: Dec,
    dec_c: Dec,
    d_elements_refcounted: bool,
) callconv(.C) RocList {
    const smaller_length = @min(list1.len(), list2.len());
    const output_length = @min(smaller_length, list3.len());

    decrementTail(list1, output_length, a_width, dec_a);
    decrementTail(list2, output_length, b_width, dec_b);
    decrementTail(list3, output_length, c_width, dec_c);

    if (data_is_owned) {
        inc_n_data(data, output_length);
    }

    if (list1.bytes) |source_a| {
        if (list2.bytes) |source_b| {
            if (list3.bytes) |source_c| {
                const output = RocList.allocate(alignment, output_length, d_width, d_elements_refcounted);
                const target_ptr = output.bytes orelse unreachable;

                var i: usize = 0;
                while (i < output_length) : (i += 1) {
                    const element_a = source_a + i * a_width;
                    const element_b = source_b + i * b_width;
                    const element_c = source_c + i * c_width;
                    const target = target_ptr + i * d_width;

                    caller(data, element_a, element_b, element_c, target);
                }

                return output;
            } else {
                return RocList.empty();
            }
        } else {
            return RocList.empty();
        }
    } else {
        return RocList.empty();
    }
}

pub fn listMap4(
    list1: RocList,
    list2: RocList,
    list3: RocList,
    list4: RocList,
    caller: Caller4,
    data: Opaque,
    inc_n_data: IncN,
    data_is_owned: bool,
    alignment: u32,
    a_width: usize,
    b_width: usize,
    c_width: usize,
    d_width: usize,
    e_width: usize,
    dec_a: Dec,
    dec_b: Dec,
    dec_c: Dec,
    dec_d: Dec,
    e_elements_refcounted: bool,
) callconv(.C) RocList {
    const output_length = @min(@min(list1.len(), list2.len()), @min(list3.len(), list4.len()));

    decrementTail(list1, output_length, a_width, dec_a);
    decrementTail(list2, output_length, b_width, dec_b);
    decrementTail(list3, output_length, c_width, dec_c);
    decrementTail(list4, output_length, d_width, dec_d);

    if (data_is_owned) {
        inc_n_data(data, output_length);
    }

    if (list1.bytes) |source_a| {
        if (list2.bytes) |source_b| {
            if (list3.bytes) |source_c| {
                if (list4.bytes) |source_d| {
                    const output = RocList.allocate(alignment, output_length, e_width, e_elements_refcounted);
                    const target_ptr = output.bytes orelse unreachable;

                    var i: usize = 0;
                    while (i < output_length) : (i += 1) {
                        const element_a = source_a + i * a_width;
                        const element_b = source_b + i * b_width;
                        const element_c = source_c + i * c_width;
                        const element_d = source_d + i * d_width;
                        const target = target_ptr + i * e_width;

                        caller(data, element_a, element_b, element_c, element_d, target);
                    }

                    return output;
                } else {
                    return RocList.empty();
                }
            } else {
                return RocList.empty();
            }
        } else {
            return RocList.empty();
        }
    } else {
        return RocList.empty();
    }
}

pub fn listWithCapacity(
    capacity: u64,
    alignment: u32,
    element_width: usize,
    elements_refcounted: bool,
    inc: Inc,
) callconv(.C) RocList {
    return listReserve(RocList.empty(), alignment, capacity, element_width, elements_refcounted, inc, .InPlace);
}

pub fn listReserve(
    list: RocList,
    alignment: u32,
    spare: u64,
    element_width: usize,
    elements_refcounted: bool,
    inc: Inc,
    update_mode: UpdateMode,
) callconv(.C) RocList {
    const original_len = list.len();
    const cap = @as(u64, @intCast(list.getCapacity()));
    const desired_cap = @as(u64, @intCast(original_len)) +| spare;

    if ((update_mode == .InPlace or list.isUnique()) and cap >= desired_cap) {
        return list;
    } else {
        // Make sure on 32-bit targets we don't accidentally wrap when we cast our U64 desired capacity to U32.
        const reserve_size: u64 = @min(desired_cap, @as(u64, @intCast(std.math.maxInt(usize))));

        var output = list.reallocate(alignment, @as(usize, @intCast(reserve_size)), element_width, elements_refcounted, inc);
        output.length = original_len;
        return output;
    }
}

pub fn listReleaseExcessCapacity(
    list: RocList,
    alignment: u32,
    element_width: usize,
    elements_refcounted: bool,
    dec: Dec,
    update_mode: UpdateMode,
) callconv(.C) RocList {
    const old_length = list.len();
    // We use the direct list.capacity_or_alloc_ptr to make sure both that there is no extra capacity and that it isn't a seamless slice.
    if ((update_mode == .InPlace or list.isUnique()) and list.capacity_or_alloc_ptr == old_length) {
        return list;
    } else if (old_length == 0) {
        list.decref(alignment, element_width, elements_refcounted, dec);
        return RocList.empty();
    } else {
        // TODO: this needs to decrement all list elements not owned by the new list.
        // Will need to use utils.decref directly to avoid extra work.
        var output = RocList.allocateExact(alignment, old_length, element_width, elements_refcounted);
        if (list.bytes) |source_ptr| {
            const dest_ptr = output.bytes orelse unreachable;

            @memcpy(dest_ptr[0..(old_length * element_width)], source_ptr[0..(old_length * element_width)]);
        }
        list.decref(alignment, element_width, elements_refcounted, dec);
        return output;
    }
}

pub fn listAppendUnsafe(
    list: RocList,
    element: Opaque,
    element_width: usize,
) callconv(.C) RocList {
    const old_length = list.len();
    var output = list;
    output.length += 1;

    if (output.bytes) |bytes| {
        if (element) |source| {
            const target = bytes + old_length * element_width;
            @memcpy(target[0..element_width], source[0..element_width]);
        }
    }

    return output;
}

fn listAppend(
    list: RocList,
    alignment: u32,
    element: Opaque,
    element_width: usize,
    elements_refcounted: bool,
    inc: Inc,
    update_mode: UpdateMode,
) callconv(.C) RocList {
    const with_capacity = listReserve(list, alignment, 1, element_width, elements_refcounted, inc, update_mode);
    return listAppendUnsafe(with_capacity, element, element_width);
}

pub fn listPrepend(
    list: RocList,
    alignment: u32,
    element: Opaque,
    element_width: usize,
    elements_refcounted: bool,
    inc: Inc,
) callconv(.C) RocList {
    const old_length = list.len();
    // TODO: properly wire in update mode.
    var with_capacity = listReserve(list, alignment, 1, element_width, elements_refcounted, inc, .Immutable);
    with_capacity.length += 1;

    // can't use one memcpy here because source and target overlap
    if (with_capacity.bytes) |target| {
        var i: usize = old_length;

        while (i > 0) {
            i -= 1;

            // move the ith element to the (i + 1)th position
            const to = target + (i + 1) * element_width;
            const from = target + i * element_width;
            @memcpy(to[0..element_width], from[0..element_width]);
        }

        // finally copy in the new first element
        if (element) |source| {
            @memcpy(target[0..element_width], source[0..element_width]);
        }
    }

    return with_capacity;
}

pub fn listSwap(
    list: RocList,
    alignment: u32,
    element_width: usize,
    index_1: u64,
    index_2: u64,
    elements_refcounted: bool,
    inc: Inc,
    dec: Dec,
    update_mode: UpdateMode,
) callconv(.C) RocList {
    // Early exit to avoid swapping the same element.
    if (index_1 == index_2)
        return list;

    const size = @as(u64, @intCast(list.len()));
    if (index_1 == index_2 or index_1 >= size or index_2 >= size) {
        // Either one index was out of bounds, or both indices were the same; just return
        return list;
    }

    const newList = blk: {
        if (update_mode == .InPlace) {
            break :blk list;
        } else {
            break :blk list.makeUnique(alignment, element_width, elements_refcounted, inc, dec);
        }
    };

    const source_ptr = @as([*]u8, @ptrCast(newList.bytes));

    swapElements(source_ptr, element_width, @as(usize,
    // We already verified that both indices are less than the stored list length,
    // which is usize, so casting them to usize will definitely be lossless.
    @intCast(index_1)), @as(usize, @intCast(index_2)));

    return newList;
}

pub fn listSublist(
    list: RocList,
    alignment: u32,
    element_width: usize,
    elements_refcounted: bool,
    start_u64: u64,
    len_u64: u64,
    dec: Dec,
) callconv(.C) RocList {
    const size = list.len();
    if (size == 0 or start_u64 >= @as(u64, @intCast(size))) {
        // Decrement the reference counts of all elements.
        if (list.bytes) |source_ptr| {
            var i: usize = 0;
            while (i < size) : (i += 1) {
                const element = source_ptr + i * element_width;
                dec(element);
            }
        }
        if (list.isUnique()) {
            var output = list;
            output.length = 0;
            return output;
        }
        list.decref(alignment, element_width, elements_refcounted, dec);
        return RocList.empty();
    }

    if (list.bytes) |source_ptr| {
        // This cast is lossless because we would have early-returned already
        // if `start_u64` were greater than `size`, and `size` fits in usize.
        const start: usize = @intCast(start_u64);

        // (size - start) can't overflow because we would have early-returned already
        // if `start` were greater than `size`.
        const size_minus_start = size - start;

        // This outer cast to usize is lossless. size, start, and size_minus_start all fit in usize,
        // and @min guarantees that if `len_u64` gets returned, it's because it was smaller
        // than something that fit in usize.
        const keep_len = @as(usize, @intCast(@min(len_u64, @as(u64, @intCast(size_minus_start)))));

        if (start == 0 and list.isUnique()) {
            // The list is unique, we actually have to decrement refcounts to elements we aren't keeping around.
            // Decrement the reference counts of elements after `start + keep_len`.
            const drop_end_len = size_minus_start - keep_len;
            var i: usize = 0;
            while (i < drop_end_len) : (i += 1) {
                const element = source_ptr + (start + keep_len + i) * element_width;
                dec(element);
            }

            var output = list;
            output.length = keep_len;
            return output;
        } else {
            if (list.isUnique()) {
                list.setAllocationElementCount(elements_refcounted);
            }
            const list_alloc_ptr = (@intFromPtr(source_ptr) >> 1) | SEAMLESS_SLICE_BIT;
            const slice_alloc_ptr = list.capacity_or_alloc_ptr;
            const slice_mask = list.seamlessSliceMask();
            const alloc_ptr = (list_alloc_ptr & ~slice_mask) | (slice_alloc_ptr & slice_mask);
            return RocList{
                .bytes = source_ptr + start * element_width,
                .length = keep_len,
                .capacity_or_alloc_ptr = alloc_ptr,
            };
        }
    }

    return RocList.empty();
}

pub fn listDropAt(
    list: RocList,
    alignment: u32,
    element_width: usize,
    elements_refcounted: bool,
    drop_index_u64: u64,
    dec: Dec,
) callconv(.C) RocList {
    const size = list.len();
    const size_u64 = @as(u64, @intCast(size));
    // If droping the first or last element, return a seamless slice.
    // For simplicity, do this by calling listSublist.
    // In the future, we can test if it is faster to manually inline the important parts here.
    if (drop_index_u64 == 0) {
        return listSublist(list, alignment, element_width, elements_refcounted, 1, size -| 1, dec);
    } else if (drop_index_u64 == size_u64 - 1) { // It's fine if (size - 1) wraps on size == 0 here,
        // because if size is 0 then it's always fine for this branch to be taken; no
        // matter what drop_index was, we're size == 0, so empty list will always be returned.
        return listSublist(list, alignment, element_width, elements_refcounted, 0, size -| 1, dec);
    }

    if (list.bytes) |source_ptr| {
        if (drop_index_u64 >= size_u64) {
            return list;
        }

        // This cast must be lossless, because we would have just early-returned if drop_index
        // were >= than `size`, and we know `size` fits in usize.
        const drop_index: usize = @intCast(drop_index_u64);

        const element = source_ptr + drop_index * element_width;
        dec(element);

        // NOTE
        // we need to return an empty list explicitly,
        // because we rely on the pointer field being null if the list is empty
        // which also requires duplicating the utils.decref call to spend the RC token
        if (size < 2) {
            list.decref(alignment, element_width, elements_refcounted, dec);
            return RocList.empty();
        }

        if (list.isUnique()) {
            var i = drop_index;
            while (i < size - 1) : (i += 1) {
                const copy_target = source_ptr + i * element_width;
                const copy_source = copy_target + element_width;

                @memcpy(copy_target[0..element_width], copy_source[0..element_width]);
            }

            var new_list = list;

            new_list.length -= 1;
            return new_list;
        }

        // TODO: all of these elements need to have their refcount incremented.
        // Also, probably use utils.decref to avoid dercementing all elements.
        const output = RocList.allocate(alignment, size - 1, element_width, elements_refcounted);
        const target_ptr = output.bytes orelse unreachable;

        const head_size = drop_index * element_width;
        @memcpy(target_ptr[0..head_size], source_ptr[0..head_size]);

        const tail_target = target_ptr + drop_index * element_width;
        const tail_source = source_ptr + (drop_index + 1) * element_width;
        const tail_size = (size - drop_index - 1) * element_width;
        @memcpy(tail_target[0..tail_size], tail_source[0..tail_size]);

        list.decref(alignment, element_width, elements_refcounted, dec);

        return output;
    } else {
        return RocList.empty();
    }
}

fn partition(source_ptr: [*]u8, transform: Opaque, wrapper: CompareFn, element_width: usize, low: isize, high: isize) isize {
    const pivot = source_ptr + (@as(usize, @intCast(high)) * element_width);
    var i = (low - 1); // Index of smaller element and indicates the right position of pivot found so far
    var j = low;

    while (j <= high - 1) : (j += 1) {
        const current_elem = source_ptr + (@as(usize, @intCast(j)) * element_width);

        const ordering = wrapper(transform, current_elem, pivot);
        const order = @as(utils.Ordering, @enumFromInt(ordering));

        switch (order) {
            utils.Ordering.LT => {
                // the current element is smaller than the pivot; swap it
                i += 1;
                swapElements(source_ptr, element_width, @as(usize, @intCast(i)), @as(usize, @intCast(j)));
            },
            utils.Ordering.EQ, utils.Ordering.GT => {},
        }
    }
    swapElements(source_ptr, element_width, @as(usize, @intCast(i + 1)), @as(usize, @intCast(high)));
    return (i + 1);
}

fn quicksort(source_ptr: [*]u8, transform: Opaque, wrapper: CompareFn, element_width: usize, low: isize, high: isize) void {
    if (low < high) {
        // partition index
        const pi = partition(source_ptr, transform, wrapper, element_width, low, high);

        _ = quicksort(source_ptr, transform, wrapper, element_width, low, pi - 1); // before pi
        _ = quicksort(source_ptr, transform, wrapper, element_width, pi + 1, high); // after pi
    }
}

pub fn listSortWith(
    input: RocList,
    caller: CompareFn,
    data: Opaque,
    inc_n_data: IncN,
    data_is_owned: bool,
    alignment: u32,
    element_width: usize,
    elements_refcounted: bool,
    inc: Inc,
    dec: Dec,
) callconv(.C) RocList {
    var list = input.makeUnique(alignment, element_width, elements_refcounted, inc, dec);

    if (data_is_owned) {
        inc_n_data(data, list.len());
    }

    if (list.bytes) |source_ptr| {
        const low = 0;
        const high: isize = @as(isize, @intCast(list.len())) - 1;
        quicksort(source_ptr, data, caller, element_width, low, high);
    }

    return list;
}

// SWAP ELEMENTS

inline fn swapHelp(width: usize, temporary: [*]u8, ptr1: [*]u8, ptr2: [*]u8) void {
    @memcpy(temporary[0..width], ptr1[0..width]);
    @memcpy(ptr1[0..width], ptr2[0..width]);
    @memcpy(ptr2[0..width], temporary[0..width]);
}

fn swap(width_initial: usize, p1: [*]u8, p2: [*]u8) void {
    const threshold: usize = 64;

    var width = width_initial;

    var ptr1 = p1;
    var ptr2 = p2;

    var buffer_actual: [threshold]u8 = undefined;
    var buffer: [*]u8 = buffer_actual[0..];

    while (true) {
        if (width < threshold) {
            swapHelp(width, buffer, ptr1, ptr2);
            return;
        } else {
            swapHelp(threshold, buffer, ptr1, ptr2);

            ptr1 += threshold;
            ptr2 += threshold;

            width -= threshold;
        }
    }
}

fn swapElements(source_ptr: [*]u8, element_width: usize, index_1: usize, index_2: usize) void {
    var element_at_i = source_ptr + (index_1 * element_width);
    var element_at_j = source_ptr + (index_2 * element_width);

    return swap(element_width, element_at_i, element_at_j);
}

pub fn listConcat(
    list_a: RocList,
    list_b: RocList,
    alignment: u32,
    element_width: usize,
    elements_refcounted: bool,
    inc: Inc,
    dec: Dec,
) callconv(.C) RocList {
    // NOTE we always use list_a! because it is owned, we must consume it, and it may have unused capacity
    if (list_b.isEmpty()) {
        if (list_a.getCapacity() == 0) {
            // a could be a seamless slice, so we still need to decref.
            list_a.decref(alignment, element_width, elements_refcounted, dec);
            return list_b;
        } else {
            // we must consume this list. Even though it has no elements, it could still have capacity
            list_b.decref(alignment, element_width, elements_refcounted, dec);

            return list_a;
        }
    } else if (list_a.isUnique()) {
        const total_length: usize = list_a.len() + list_b.len();

        const resized_list_a = list_a.reallocate(alignment, total_length, element_width, elements_refcounted, inc);

        // These must exist, otherwise, the lists would have been empty.
        const source_a = resized_list_a.bytes orelse unreachable;
        const source_b = list_b.bytes orelse unreachable;
        @memcpy(source_a[(list_a.len() * element_width)..(total_length * element_width)], source_b[0..(list_b.len() * element_width)]);

        // decrement list b.
        list_b.decref(alignment, element_width, elements_refcounted, dec);

        return resized_list_a;
    } else if (list_b.isUnique()) {
        const total_length: usize = list_a.len() + list_b.len();

        const resized_list_b = list_b.reallocate(alignment, total_length, element_width, elements_refcounted, inc);

        // These must exist, otherwise, the lists would have been empty.
        const source_a = list_a.bytes orelse unreachable;
        const source_b = resized_list_b.bytes orelse unreachable;

        // This is a bit special, we need to first copy the elements of list_b to the end,
        // then copy the elements of list_a to the beginning.
        // This first call must use mem.copy because the slices might overlap.
        const byte_count_a = list_a.len() * element_width;
        const byte_count_b = list_b.len() * element_width;
        mem.copyBackwards(u8, source_b[byte_count_a .. byte_count_a + byte_count_b], source_b[0..byte_count_b]);
        @memcpy(source_b[0..byte_count_a], source_a[0..byte_count_a]);

        // decrement list a.
        list_a.decref(alignment, element_width, elements_refcounted, dec);

        return resized_list_b;
    }
    const total_length: usize = list_a.len() + list_b.len();

    const output = RocList.allocate(alignment, total_length, element_width, elements_refcounted);

    // These must exist, otherwise, the lists would have been empty.
    const target = output.bytes orelse unreachable;
    const source_a = list_a.bytes orelse unreachable;
    const source_b = list_b.bytes orelse unreachable;

    @memcpy(target[0..(list_a.len() * element_width)], source_a[0..(list_a.len() * element_width)]);
    @memcpy(target[(list_a.len() * element_width)..(total_length * element_width)], source_b[0..(list_b.len() * element_width)]);

    // decrement list a and b.
    list_a.decref(alignment, element_width, elements_refcounted, dec);
    list_b.decref(alignment, element_width, elements_refcounted, dec);

    return output;
}

pub fn listReplaceInPlace(
    list: RocList,
    index: u64,
    element: Opaque,
    element_width: usize,
    out_element: ?[*]u8,
) callconv(.C) RocList {
    // INVARIANT: bounds checking happens on the roc side
    //
    // at the time of writing, the function is implemented roughly as
    // `if inBounds then LowLevelListReplace input index item else input`
    // so we don't do a bounds check here. Hence, the list is also non-empty,
    // because inserting into an empty list is always out of bounds,
    // and it's always safe to cast index to usize.
    return listReplaceInPlaceHelp(list, @as(usize, @intCast(index)), element, element_width, out_element);
}

pub fn listReplace(
    list: RocList,
    alignment: u32,
    index: u64,
    element: Opaque,
    element_width: usize,
    elements_refcounted: bool,
    inc: Inc,
    dec: Dec,
    out_element: ?[*]u8,
) callconv(.C) RocList {
    // INVARIANT: bounds checking happens on the roc side
    //
    // at the time of writing, the function is implemented roughly as
    // `if inBounds then LowLevelListReplace input index item else input`
    // so we don't do a bounds check here. Hence, the list is also non-empty,
    // because inserting into an empty list is always out of bounds,
    // and it's always safe to cast index to usize.
    // because inserting into an empty list is always out of bounds
    return listReplaceInPlaceHelp(list.makeUnique(alignment, element_width, elements_refcounted, inc, dec), @as(usize, @intCast(index)), element, element_width, out_element);
}

inline fn listReplaceInPlaceHelp(
    list: RocList,
    index: usize,
    element: Opaque,
    element_width: usize,
    out_element: ?[*]u8,
) RocList {
    // the element we will replace
    var element_at_index = (list.bytes orelse unreachable) + (index * element_width);

    // copy out the old element
    @memcpy((out_element orelse unreachable)[0..element_width], element_at_index[0..element_width]);

    // copy in the new element
    @memcpy(element_at_index[0..element_width], (element orelse unreachable)[0..element_width]);

    return list;
}

pub fn listIsUnique(
    list: RocList,
) callconv(.C) bool {
    return list.isEmpty() or list.isUnique();
}

pub fn listClone(
    list: RocList,
    alignment: u32,
    element_width: usize,
    elements_refcounted: bool,
    inc: Inc,
    dec: Dec,
) callconv(.C) RocList {
    return list.makeUnique(alignment, element_width, elements_refcounted, inc, dec);
}

pub fn listCapacity(
    list: RocList,
) callconv(.C) usize {
    return list.getCapacity();
}

pub fn listAllocationPtr(
    list: RocList,
) callconv(.C) ?[*]u8 {
    return list.getAllocationPtr();
}

fn rcNone(_: ?[*]u8) callconv(.C) void {}

test "listConcat: non-unique with unique overlapping" {
    var nonUnique = RocList.fromSlice(u8, ([_]u8{1})[0..], false);
    var bytes: [*]u8 = @as([*]u8, @ptrCast(nonUnique.bytes));
    const ptr_width = @sizeOf(usize);
    const refcount_ptr = @as([*]isize, @ptrCast(@as([*]align(ptr_width) u8, @alignCast(bytes)) - ptr_width));
    utils.increfRcPtrC(&refcount_ptr[0], 1);
    defer nonUnique.decref(@alignOf(u8), @sizeOf(u8), false, rcNone); // listConcat will dec the other refcount

    var unique = RocList.fromSlice(u8, ([_]u8{ 2, 3, 4 })[0..], false);
    defer unique.decref(@alignOf(u8), @sizeOf(u8), false, rcNone);

    var concatted = listConcat(nonUnique, unique, 1, 1, false, rcNone, rcNone);
    var wanted = RocList.fromSlice(u8, ([_]u8{ 1, 2, 3, 4 })[0..], false);
    defer wanted.decref(@alignOf(u8), @sizeOf(u8), false, rcNone);

    try expect(concatted.eql(wanted));
}
