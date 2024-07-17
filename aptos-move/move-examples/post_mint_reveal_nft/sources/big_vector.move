module post_mint_reveal_nft::big_vector {
    use std::error;
    use std::vector;
    use aptos_std::table_with_length::{Self, TableWithLength};

    /// Vector index is out of bounds
    const EINDEX_OUT_OF_BOUNDS: u64 = 1;
    /// Cannot destroy a non-empty vector
    const EVECTOR_NOT_EMPTY: u64 = 2;
    /// Cannot pop back from an empty vector
    const EVECTOR_EMPTY: u64 = 3;
    /// bucket_size cannot be 0
    const EZERO_BUCKET_SIZE: u64 = 4;

    /// A scalable vector implementation based on tables where elements are grouped into buckets.
    /// Each bucket has a capacity of `bucket_size` elements.
    struct BigVector<T> has store {
        buckets: TableWithLength<u64, vector<T>>,
        end_index: u64,
        bucket_size: u64
    }

    /// Regular Vector API

    /// Create an empty vector.
    public fun empty<T: store>(bucket_size: u64): BigVector<T> {
        assert!(bucket_size > 0, error::invalid_argument(EZERO_BUCKET_SIZE));
        BigVector {
            buckets: table_with_length::new(),
            end_index: 0,
            bucket_size,
        }
    }

    /// Create a vector of length 1 containing the passed in element.
    public fun singleton<T: store>(element: T, bucket_size: u64): BigVector<T> {
        let v = empty(bucket_size);
        v.push_back(element);
        v
    }

    /// Destroy the vector `v`.
    /// Aborts if `v` is not empty.
    public fun destroy_empty<T>(self: BigVector<T>) {
        assert!(self.is_empty(), error::invalid_argument(EVECTOR_NOT_EMPTY));
        let BigVector { buckets, end_index: _,  bucket_size: _ } = self;
        table_with_length::destroy_empty(buckets);
    }

    /// Acquire an immutable reference to the `i`th element of the vector `v`.
    /// Aborts if `i` is out of bounds.
    public fun borrow<T>(self: &BigVector<T>, i: u64): &T {
        assert!(i < self.length(), error::invalid_argument(EINDEX_OUT_OF_BOUNDS));
        vector::borrow(table_with_length::borrow(&self.buckets, i / self.bucket_size), i % self.bucket_size)
    }

    /// Return a mutable reference to the `i`th element in the vector `v`.
    /// Aborts if `i` is out of bounds.
    public fun borrow_mut<T>(self: &mut BigVector<T>, i: u64): &mut T {
        assert!(i < self.length(), error::invalid_argument(EINDEX_OUT_OF_BOUNDS));
        vector::borrow_mut(table_with_length::borrow_mut(&mut self.buckets, i / self.bucket_size), i % self.bucket_size)
    }

    /// Empty and destroy the other vector, and push each of the elements in the other vector onto the lhs vector in the
    /// same order as they occurred in other.
    /// Disclaimer: This function is costly. Use it at your own discretion.
    public fun append<T: store>(self: &mut BigVector<T>, other: BigVector<T>) {
        let other_len = other.length();
        let half_other_len = other_len / 2;
        let i = 0;
        while (i < half_other_len) {
            self.push_back(other.swap_remove(i));
            i = i + 1;
        };
        while (i < other_len) {
            self.push_back(other.pop_back());
            i = i + 1;
        };
        other.destroy_empty();
    }

    /// Add element `val` to the end of the vector `v`. It grows the buckets when the current buckets are full.
    /// This operation will cost more gas when it adds new bucket.
    public fun push_back<T: store>(self: &mut BigVector<T>, val: T) {
        let num_buckets = table_with_length::length(&self.buckets);
        if (self.end_index == num_buckets * self.bucket_size) {
            table_with_length::add(&mut self.buckets, num_buckets, vector::empty());
            vector::push_back(table_with_length::borrow_mut(&mut self.buckets, num_buckets), val);
        } else {
            vector::push_back(table_with_length::borrow_mut(&mut self.buckets, num_buckets - 1), val);
        };
        self.end_index = self.end_index + 1;
    }

    /// Pop an element from the end of vector `v`. It doesn't shrink the buckets even if they're empty.
    /// Call `shrink_to_fit` explicity to deallocate empty buckets.
    /// Aborts if `v` is empty.
    public fun pop_back<T>(self: &mut BigVector<T>): T {
        assert!(!self.is_empty(), error::invalid_state(EVECTOR_EMPTY));
        let num_buckets = table_with_length::length(&self.buckets);
        let last_bucket = table_with_length::borrow_mut(&mut self.buckets, num_buckets - 1);
        let val = vector::pop_back(last_bucket);
        // Shrink the table if the last vector is empty.
        if (vector::is_empty(last_bucket)) {
            move last_bucket;
            vector::destroy_empty(table_with_length::remove(&mut self.buckets, num_buckets - 1));
        };
        self.end_index = self.end_index - 1;
        val
    }

    /// Remove the element at index i in the vector v and return the owned value that was previously stored at i in v.
    /// All elements occurring at indices greater than i will be shifted down by 1. Will abort if i is out of bounds.
    /// Disclaimer: This function is costly. Use it at your own discretion.
    public fun remove<T>(self: &mut BigVector<T>, i: u64): T {
        let len = self.length();
        assert!(i < len, error::invalid_argument(EINDEX_OUT_OF_BOUNDS));
        while (i + 1 < len) {
            self.swap(i, i + 1);
            i = i + 1;
        };
        self.pop_back()
    }

    /// Swap the `i`th element of the vector `v` with the last element and then pop the vector.
    /// This is O(1), but does not preserve ordering of elements in the vector.
    /// Aborts if `i` is out of bounds.
    public fun swap_remove<T>(self: &mut BigVector<T>, i: u64): T {
        assert!(i < self.length(), error::invalid_argument(EINDEX_OUT_OF_BOUNDS));
        let last_val = self.pop_back();
        // if the requested value is the last one, return it
        if (self.end_index == i) {
            return last_val
        };
        // because the lack of mem::swap, here we swap remove the requested value from the bucket
        // and append the last_val to the bucket then swap the last bucket val back
        let bucket = table_with_length::borrow_mut(&mut self.buckets, i / self.bucket_size);
        let bucket_len = vector::length(bucket);
        let val = vector::swap_remove(bucket, i % self.bucket_size);
        vector::push_back(bucket, last_val);
        vector::swap(bucket, i % self.bucket_size, bucket_len - 1);
        val
    }

    /// Swap the elements at the i'th and j'th indices in the vector v. Will abort if either of i or j are out of bounds
    /// for v.
    public fun swap<T>(self: &mut BigVector<T>, i: u64, j: u64) {
        assert!(i < self.length() && j < self.length(), error::invalid_argument(EINDEX_OUT_OF_BOUNDS));
        let i_bucket_index = i / self.bucket_size;
        let j_bucket_index = j / self.bucket_size;
        let i_vector_index = i % self.bucket_size;
        let j_vector_index = j % self.bucket_size;
        if (i_bucket_index == j_bucket_index) {
            vector::swap(table_with_length::borrow_mut(&mut self.buckets, i_bucket_index), i_vector_index, j_vector_index);
            return
        };
        // If i and j are in different buckets, take the buckets out first for easy mutation.
        let bucket_i = table_with_length::remove(&mut self.buckets, i_bucket_index);
        let bucket_j = table_with_length::remove(&mut self.buckets, j_bucket_index);
        // Get the elements from buckets by calling `swap_remove`.
        let element_i = vector::swap_remove(&mut bucket_i, i_vector_index);
        let element_j = vector::swap_remove(&mut bucket_j, j_vector_index);
        // Swap the elements and push back to the other bucket.
        vector::push_back(&mut bucket_i, element_j);
        vector::push_back(&mut bucket_j, element_i);
        let last_index_in_bucket_i = vector::length(&bucket_i) - 1;
        let last_index_in_bucket_j = vector::length(&bucket_j) - 1;
        // Re-position the swapped elements to the right index.
        vector::swap(&mut bucket_i, i_vector_index, last_index_in_bucket_i);
        vector::swap(&mut bucket_j, j_vector_index, last_index_in_bucket_j);
        // Add back the buckets.
        table_with_length::add(&mut self.buckets, i_bucket_index, bucket_i);
        table_with_length::add(&mut self.buckets, j_bucket_index, bucket_j);
    }

    /// Reverse the order of the elements in the vector v in-place.
    /// Disclaimer: This function is costly. Use it at your own discretion.
    public fun reverse<T>(self: &mut BigVector<T>) {
        let len = self.length();
        let half_len = len / 2;
        let k = 0;
        while (k < half_len) {
            self.swap(k, len - 1 - k);
            k = k + 1;
        }
    }

    /// Return the index of the first occurrence of an element in v that is equal to e. Returns (true, index) if such an
    /// element was found, and (false, 0) otherwise.
    /// Disclaimer: This function is costly. Use it at your own discretion.
    public fun index_of<T>(self: &BigVector<T>, val: &T): (bool, u64) {
        let i = 0;
        let len = self.length();
        while (i < len) {
            if (self.borrow(i) == val) {
                return (true, i)
            };
            i = i + 1;
        };
        (false, 0)
    }

    /// Return if an element equal to e exists in the vector v.
    /// Disclaimer: This function is costly. Use it at your own discretion.
    public fun contains<T>(self: &BigVector<T>, val: &T): bool {
        if (self.is_empty()) return false;
        let (exist, _) = self.index_of(val);
        exist
    }

    /// Return the length of the vector.
    public fun length<T>(self: &BigVector<T>): u64 {
        self.end_index
    }

    /// Return `true` if the vector `v` has no elements and `false` otherwise.
    public fun is_empty<T>(self: &BigVector<T>): bool {
        self.length() == 0
    }

    #[test_only]
    fun destroy<T: drop>(self: BigVector<T>) {
        while (!self.is_empty()) {
            self.pop_back();
        };
        self.destroy_empty()
    }

    #[test]
    fun big_vector_test() {
        let v = empty(5);
        let i = 0;
        while (i < 100) {
            v.push_back(i);
            i = i + 1;
        };
        let j = 0;
        while (j < 100) {
            let val = v.borrow(j);
            assert!(*val == j, 0);
            j = j + 1;
        };
        while (i > 0) {
            i = i - 1;
            let (exist, index) = v.index_of(&i);
            let j = v.pop_back();
            assert!(exist, 0);
            assert!(index == i, 0);
            assert!(j == i, 0);
        };
        while (i < 100) {
            v.push_back(i);
            i = i + 1;
        };
        let last_index = v.length() - 1;
        assert!(v.swap_remove(last_index) == 99, 0);
        assert!(v.swap_remove(0) == 0, 0);
        while (v.length() > 0) {
            // the vector is always [N, 1, 2, ... N-1] with repetitive swap_remove(&mut v, 0)
            let expected = v.length();
            let val = v.swap_remove(0);
            assert!(val == expected, 0);
        };
        v.destroy_empty();
    }

    #[test]
    fun big_vector_append_edge_case_test() {
        let v1 = empty(5);
        let v2 = singleton(1u64, 7);
        let v3 = empty(6);
        let v4 = empty(8);
        v3.append(v4);
        assert!(v3.length() == 0, 0);
        v2.append(v3);
        assert!(v2.length() == 1, 0);
        v1.append(v2);
        assert!(v1.length() == 1, 0);
        v1.destroy();
    }

    #[test]
    fun big_vector_append_test() {
        let v1 = empty(5);
        let v2 = empty(7);
        let i = 0;
        while (i < 7) {
            v1.push_back(i);
            i = i + 1;
        };
        while (i < 25) {
            v2.push_back(i);
            i = i + 1;
        };
        v1.append(v2);
        assert!(v1.length() == 25, 0);
        i = 0;
        while (i < 25) {
            assert!(*v1.borrow(i) == i, 0);
            i = i + 1;
        };
        v1.destroy();
    }

    #[test]
    fun big_vector_remove_and_reverse_test() {
        let v = empty(11);
        let i = 0;
        while (i < 101) {
            v.push_back(i);
            i = i + 1;
        };
        v.remove(100);
        v.remove(90);
        v.remove(80);
        v.remove(70);
        v.remove(60);
        v.remove(50);
        v.remove(40);
        v.remove(30);
        v.remove(20);
        v.remove(10);
        v.remove(0);
        assert!(v.length() == 90, 0);

        let index = 0;
        i = 0;
        while (i < 101) {
            if (i % 10 != 0) {
                assert!(*v.borrow(index) == i, 0);
                index = index + 1;
            };
            i = i + 1;
        };
        v.destroy();
    }

    #[test]
    fun big_vector_swap_test() {
        let v = empty(11);
        let i = 0;
        while (i < 101) {
            v.push_back(i);
            i = i + 1;
        };
        i = 0;
        while (i < 51) {
            v.swap(i, 100 - i);
            i = i + 1;
        };
        i = 0;
        while (i < 101) {
            assert!(*v.borrow(i) == 100 - i, 0);
            i = i + 1;
        };
        v.destroy();
    }

    #[test]
    fun big_vector_index_of_test() {
        let v = empty(11);
        let i = 0;
        while (i < 100) {
            v.push_back(i);
            let (found, idx) = v.index_of(&i);
            assert!(found && idx == i, 0);
            i = i + 1;
        };
        v.destroy();
    }

    #[test]
    fun big_vector_empty_contains() {
        let v = empty<u64> (10);
        assert!(!v.contains(&(1 as u64)), 0);
        v.destroy_empty();
    }
}
