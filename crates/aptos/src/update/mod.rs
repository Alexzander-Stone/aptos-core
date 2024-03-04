// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

mod aptos;
mod revela;
mod tool;

use crate::common::types::CliTypedResult;
use anyhow::{anyhow, Context, Result};
use self_update::{update::ReleaseUpdate, Status};
pub use tool::UpdateTool;

/// Things that implement this trait are able to update a binary.
trait BinaryUpdater {
    fn pretty_name(&self) -> &'static str;

    fn get_update_info(&self) -> Result<UpdateRequiredInfo>;

    fn build_self_updater(&self, info: &UpdateRequiredInfo) -> Result<Box<dyn ReleaseUpdate>>;

    fn update(&self) -> CliTypedResult<String> {
        // Confirm that we need to update.
        let info = self
            .get_update_info()
            .context("Failed to check if we need to update")?;
        if !info.update_required {
            return Ok(format!("Already up to date (v{})", info.target_version));
        }

        // Build the updater.
        let updater = self.build_self_updater(&info)?;

        // Update the binary.
        let result = updater
            .update()
            .map_err(|e| anyhow!("Failed to update {}: {:#}", self.pretty_name(), e))?;

        let message = match result {
            Status::UpToDate(_) => unreachable!("We should have caught this already"),
            Status::Updated(_) => format!(
                "Successfully updated {} from v{} to v{}",
                self.pretty_name(),
                info.current_version,
                info.target_version
            ),
        };

        Ok(message)
    }
}

// todo rename latest to target
// todo consider merging the target version fields
#[derive(Debug)]
pub struct UpdateRequiredInfo {
    pub update_required: bool,
    pub current_version: String,
    pub target_version: String,
    pub target_version_tag: String,
}
