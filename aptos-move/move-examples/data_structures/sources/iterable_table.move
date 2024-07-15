module aptos_std::iterable_table {
    use std::option::{Self, Option};
    use aptos_std::table_with_length::{Self, TableWithLength};

    /// The iterable wrapper around value, points to previous and next key if any.
    struct IterableValue<K: copy + store + drop, V: store> has store {
        val: V,
        prev: Option<K>,
        next: Option<K>,
    }

    /// An iterable table implementation based on double linked list.
    struct IterableTable<K: copy + store + drop, V: store> has store {
        inner: TableWithLength<K, IterableValue<K, V>>,
        head: Option<K>,
        tail: Option<K>,
    }

    /// Regular table API.

    /// Create an empty table.
    public fun new<K: copy + store + drop, V: store>(): IterableTable<K, V> {
        IterableTable {
            inner: table_with_length::new(),
            head: option::none(),
            tail: option::none(),
        }
    }

    /// Destroy a table. The table must be empty to succeed.
    public fun destroy_empty<K: copy + store + drop, V: store>(self: IterableTable<K, V>) {
        assert!(self.empty(), 0);
        assert!(option::is_none(&self.head), 0);
        assert!(option::is_none(&self.tail), 0);
        let IterableTable {inner, head: _, tail: _} = self;
        table_with_length::destroy_empty(inner);
    }

    /// Add a new entry to the table. Aborts if an entry for this
    /// key already exists.
    public fun add<K: copy + store + drop, V: store>(self: &mut IterableTable<K, V>, key: K, val: V) {
        let wrapped_value = IterableValue {
            val,
            prev: self.tail,
            next: option::none(),
        };
        table_with_length::add(&mut self.inner, key, wrapped_value);
        if (option::is_some(&self.tail)) {
            let k = option::borrow(&self.tail);
            table_with_length::borrow_mut(&mut self.inner, *k).next = option::some(key);
        } else {
            self.head = option::some(key);
        };
        self.tail = option::some(key);
    }

    /// Remove from `table` and return the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun remove<K: copy + store + drop, V: store>(self: &mut IterableTable<K, V>, key: K): V {
        let (val, _, _) = self.remove_iter(key);
        val
    }

    /// Acquire an immutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow<K: copy + store + drop, V: store>(self: &IterableTable<K, V>, key: K): &V {
        &table_with_length::borrow(&self.inner, key).val
    }

    /// Acquire a mutable reference to the value which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow_mut<K: copy + store + drop, V: store>(self: &mut IterableTable<K, V>, key: K): &mut V {
        &mut table_with_length::borrow_mut(&mut self.inner, key).val
    }

    /// Acquire a mutable reference to the value which `key` maps to.
    /// Insert the pair (`key`, `default`) first if there is no entry for `key`.
    public fun borrow_mut_with_default<K: copy + store + drop, V: store + drop>(self: &mut IterableTable<K, V>, key: K, default: V): &mut V {
        if (!self.contains(key)) {
            self.add(key, default)
        };
        self.borrow_mut(key)
    }

    /// Returns the length of the table, i.e. the number of entries.
    public fun length<K: copy + store + drop, V: store>(self: &IterableTable<K, V>): u64 {
        table_with_length::length(&self.inner)
    }

    /// Returns true if this table is empty.
    public fun empty<K: copy + store + drop, V: store>(self: &IterableTable<K, V>): bool {
        table_with_length::empty(&self.inner)
    }

    /// Returns true iff `table` contains an entry for `key`.
    public fun contains<K: copy + store + drop, V: store>(self: &IterableTable<K, V>, key: K): bool {
        table_with_length::contains(&self.inner, key)
    }

    /// Iterable API.

    /// Returns the key of the head for iteration.
    public fun head_key<K: copy + store + drop, V: store>(self: &IterableTable<K, V>): Option<K> {
        self.head
    }

    /// Returns the key of the tail for iteration.
    public fun tail_key<K: copy + store + drop, V: store>(self: &IterableTable<K, V>): Option<K> {
        self.tail
    }

    /// Acquire an immutable reference to the IterableValue which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow_iter<K: copy + store + drop, V: store>(self: &IterableTable<K, V>, key: K): (&V, Option<K>, Option<K>) {
        let v = table_with_length::borrow(&self.inner, key);
        (&v.val, v.prev, v.next)
    }

    /// Acquire a mutable reference to the value and previous/next key which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun borrow_iter_mut<K: copy + store + drop, V: store>(self: &mut IterableTable<K, V>, key: K): (&mut V, Option<K>, Option<K>) {
        let v = table_with_length::borrow_mut(&mut self.inner, key);
        (&mut v.val, v.prev, v.next)
    }

    /// Remove from `table` and return the value and previous/next key which `key` maps to.
    /// Aborts if there is no entry for `key`.
    public fun remove_iter<K: copy + store + drop, V: store>(self: &mut IterableTable<K, V>, key: K): (V, Option<K>, Option<K>) {
        let val = table_with_length::remove(&mut self.inner, copy key);
        if (option::contains(&self.tail, &key)) {
            self.tail = val.prev;
        };
        if (option::contains(&self.head, &key)) {
            self.head = val.next;
        };
        if (option::is_some(&val.prev)) {
            let key = option::borrow(&val.prev);
            table_with_length::borrow_mut(&mut self.inner, *key).next = val.next;
        };
        if (option::is_some(&val.next)) {
            let key = option::borrow(&val.next);
            table_with_length::borrow_mut(&mut self.inner, *key).prev = val.prev;
        };
        let IterableValue {val, prev, next} = val;
        (val, prev, next)
    }

    /// Remove all items from v2 and append to v1.
    public fun append<K: copy + store + drop, V: store>(self: &mut IterableTable<K, V>, v2: &mut IterableTable<K, V>) {
        let key = v2.head_key();
        while (option::is_some(&key)) {
            let (val, _, next) = v2.remove_iter(*option::borrow(&key));
            self.add(*option::borrow(&key), val);
            key = next;
        };
    }

    #[test]
    fun iterable_table_test() {
        let table = new();
        let i = 0;
        while (i < 100) {
            table.add(i, i);
            i = i + 1;
        };
        assert!(table.length() == 100, 0);
        i = 0;
        while (i < 100) {
            assert!(table.remove(i) == i, 0);
            i = i + 2;
        };
        assert!(!table.empty(), 0);
        let key = table.head_key();
        i = 1;
        while (option::is_some(&key)) {
            let (val, _, next) = table.borrow_iter(*option::borrow(&key));
            assert!(*val == i, 0);
            key = next;
            i = i + 2;
        };
        assert!(i == 101, 0);
        let table2 = new();
        table2.append(&mut table);
        table.destroy_empty();
        let key = table2.tail_key();
        while (option::is_some(&key)) {
            let (val, prev, _) = table2.remove_iter(*option::borrow(&key));
            assert!(val == *option::borrow(&key), 0);
            key = prev;
        };
        table2.destroy_empty();
    }
}
