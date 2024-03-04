// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

//! Implements the "dead store elimination" transformation.
//!
//! This transformation should be run after the variable coalescing transformation,
//! as it removes the dead stores that variable coalescing may introduce.
//!
//! prerequisite: the `LiveVarAnnotation` should already be computed by running the
//! `LiveVarAnalysisProcessor` in the `track_all_usages` mode.
//! side effect: all annotations will be removed from the function target annotations.
//!
//! Given live variables and all their usages at each program point,
//! this transformation removes dead stores, i.e., assignments and loads to locals which
//! are not live afterwards (or are live only in dead code, making them effectively dead).
//! In addition, it also removes self-assignments, i.e., assignments of the form `x = x`.

use crate::pipeline::livevar_analysis_processor::LiveVarAnnotation;
use move_binary_format::file_format::CodeOffset;
use move_model::{ast::TempIndex, model::FunctionEnv};
use move_stackless_bytecode::{
    function_target::{FunctionData, FunctionTarget},
    function_target_pipeline::{FunctionTargetProcessor, FunctionTargetsHolder},
    stackless_bytecode::Bytecode,
};
use std::collections::{BTreeMap, BTreeSet};

/// A definition-use graph, where:
/// - each node is a code offset, representing a definition and/or a use of a local.
/// - a forward edge (`children`) `a -> b` means that the definition at `a` is used at `b`.
/// - each forward edge `a -> b` has a corresponding backward edge (`parents`) `a <- b`.
/// - nodes that are known to be dead stores are marked as `dead`.
///
/// Note that this graph only contains side-effect-free *definitions* of the form:
/// - `Assign(dst, src)`
/// - `Load(dst, constant)`
/// This is a conservative over-approximation of side-effect-free definitions.
/// The nodes representing only *uses* have no restrictions like for definitions.
/// A node can represent both a definition and a use: such a node can only be of the
/// form `Assign(dst, src)`, which follows from the above restrictions.
/// As such, many code offsets in a function that do not meet the above criteria
/// may not be present in this graph.
///
/// A side-effect-free definition can be removed safely if it is not alive later.
struct DefUseGraph {
    children: BTreeMap<CodeOffset, BTreeSet<CodeOffset>>,
    parents: BTreeMap<CodeOffset, BTreeSet<CodeOffset>>,
    dead: BTreeSet<CodeOffset>,
}

impl DefUseGraph {
    /// Create a new `DefUseGraph` from the function `target`.
    pub fn new(target: &FunctionTarget) -> Self {
        let mut this = Self {
            children: BTreeMap::new(),
            parents: BTreeMap::new(),
            dead: BTreeSet::new(),
        };
        this.populate_from(target);
        this
    }

    /// Obtain the set of dead stores, i.e., code offsets which can be removed safely.
    pub fn dead_stores(mut self) -> BTreeSet<CodeOffset> {
        let mut dead = BTreeSet::new();
        while let Some(offset) = self.remove_a_dead_node() {
            dead.insert(offset);
        }
        dead
    }

    /// Populate an empty graph from the (restricted) definitions and uses in `target`.
    fn populate_from(&mut self, target: &FunctionTarget) {
        let code = target.get_bytecode();
        let live_vars = target
            .get_annotations()
            .get::<LiveVarAnnotation>()
            .expect("live variable annotation is a prerequisite");
        for (offset, instr) in code.iter().enumerate() {
            use Bytecode::*;
            match instr {
                Assign(_, dst, src, _) if dst == src => {
                    // self-assignment is always a dead store
                    self.incorporate_definition(*dst, offset as CodeOffset, live_vars, true);
                },
                Assign(_, dst, ..) | Load(_, dst, _) => {
                    self.incorporate_definition(*dst, offset as CodeOffset, live_vars, false);
                },
                _ => {},
            }
        }
    }

    /// Remove one dead node (arbitrary but deterministic) from the graph, if present.
    fn remove_a_dead_node(&mut self) -> Option<CodeOffset> {
        if let Some(node) = self.dead.pop_last() {
            let parents = self.disconnect_from_parents(node);
            let children = self.disconnect_from_children(node);
            // Reconnect all parents to all children.
            for parent in parents.iter() {
                for child in children.iter() {
                    self.children.entry(*parent).or_default().insert(*child);
                    self.parents.entry(*child).or_default().insert(*parent);
                }
            }
            // Parents are the only ones who could become dead (if `node` was their last child).
            parents
                .iter()
                .for_each(|parent| self.re_evaluate_death(*parent));
            Some(node)
        } else {
            None
        }
    }

    /// Check if a `parent` node is now dead, and mark it as such if it is.
    /// A parent node is always a (restricted) definition, and is dead if all its children are dead.
    fn re_evaluate_death(&mut self, parent: CodeOffset) {
        if let Some(children) = self.children.get(&parent) {
            if children.iter().all(|child| self.dead.contains(child)) {
                self.dead.insert(parent);
            }
        } else {
            self.dead.insert(parent);
        }
    }

    /// Disconnect `node` from its parents and return the set of parents.
    fn disconnect_from_parents(&mut self, node: CodeOffset) -> BTreeSet<CodeOffset> {
        if let Some(parents) = self.parents.remove(&node) {
            for parent in parents.iter() {
                let children = self
                    .children
                    .get_mut(parent)
                    .expect("parent of a child must have children");
                children.remove(&node);
            }
            parents
        } else {
            BTreeSet::new()
        }
    }

    /// Disconnect `node` from its children and return the set of children.
    fn disconnect_from_children(&mut self, node: CodeOffset) -> BTreeSet<CodeOffset> {
        if let Some(children) = self.children.remove(&node) {
            for child in children.iter() {
                let parents = self
                    .parents
                    .get_mut(child)
                    .expect("child of a parent must have parents");
                parents.remove(&node);
            }
            children
        } else {
            BTreeSet::new()
        }
    }

    /// Incorporate a definition `def` at `offset` into the graph, using the `live_vars` annotation.
    /// If `always_mark` is true, the definition is marked as dead regardless of its liveness.
    fn incorporate_definition(
        &mut self,
        def: TempIndex,
        offset: CodeOffset,
        live_vars: &LiveVarAnnotation,
        always_mark: bool,
    ) {
        let live_after = live_vars.get_info_at(offset).after.get(&def);
        if let Some(live) = live_after {
            if always_mark {
                self.dead.insert(offset);
            }
            let children = self.children.entry(offset).or_default();
            live.usage_offsets().iter().for_each(|child| {
                children.insert(*child);
                self.parents.entry(*child).or_default().insert(offset);
            });
        } else {
            self.dead.insert(offset);
        }
    }
}

/// A processor which performs dead store elimination transformation.
pub struct DeadStoreElimination {}

impl DeadStoreElimination {
    /// Transforms the `code` of a function by removing the instructions corresponding to
    /// the code offsets contained in `dead_stores`.
    ///
    /// Returns the transformed code.
    fn transform(target: &FunctionTarget, dead_stores: BTreeSet<CodeOffset>) -> Vec<Bytecode> {
        let mut new_code = vec![];
        let code = target.get_bytecode();
        for (offset, instr) in code.iter().enumerate() {
            if !dead_stores.contains(&(offset as CodeOffset)) {
                new_code.push(instr.clone());
            }
        }
        new_code
    }
}

impl FunctionTargetProcessor for DeadStoreElimination {
    fn process(
        &self,
        _targets: &mut FunctionTargetsHolder,
        func_env: &FunctionEnv,
        mut data: FunctionData,
        _scc_opt: Option<&[FunctionEnv]>,
    ) -> FunctionData {
        if func_env.is_native() {
            return data;
        }
        let target = FunctionTarget::new(func_env, &data);
        let def_use_graph = DefUseGraph::new(&target);
        let dead_stores = def_use_graph.dead_stores();
        let new_code = Self::transform(&target, dead_stores);
        // Note that the file format generator will not include unused locals in the generated code,
        // so we don't need to prune unused locals here for various fields of `data` (like `local_types`).
        data.code = new_code;
        // Annotations may no longer be valid after this transformation because code offsets have changed.
        // So remove them.
        data.annotations.clear();
        data
    }

    fn name(&self) -> String {
        "DeadStoreElimination".to_string()
    }
}
