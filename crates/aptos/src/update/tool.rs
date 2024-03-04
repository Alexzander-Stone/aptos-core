// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

// Out of the box the self_update crate assumes that you have releases named a
// specific way with the crate name, version, and target triple in a specific
// format. We don't do this with our releases, we have other GitHub releases beyond
// just the CLI, and we don't build for all major target triples, so we have to do
// some of the work ourselves first to figure out what the latest version of the
// CLI is and which binary to download based on the current OS. Then we can plug
// that into the library which takes care of the rest.

use super::{aptos::AptosUpdateTool, revela::RevelaUpdateTool};
use crate::common::types::{CliCommand, CliResult};
use clap::Subcommand;

/// Update the CLI or binaries it depends on.
///
/// This can be used to update the CLI to the latest version. This is useful if you
/// installed the CLI via the install script / by downloading the binary directly.
#[derive(Subcommand)]
pub enum UpdateTool {
    Aptos(AptosUpdateTool),
    Revela(RevelaUpdateTool),
}

impl UpdateTool {
    pub async fn execute(self) -> CliResult {
        match self {
            UpdateTool::Aptos(tool) => tool.execute_serialized().await,
            UpdateTool::Revela(tool) => tool.execute_serialized().await,
        }
    }
}
