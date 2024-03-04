// Copyright © Aptos Foundation
// SPDX-License-Identifier: Apache-2.0

use super::{BinaryUpdater, UpdateRequiredInfo};
use crate::common::{
    types::{CliCommand, CliTypedResult},
    utils::cli_build_information,
};
use anyhow::{anyhow, bail, Context, Result};
use aptos_build_info::BUILD_OS;
use async_trait::async_trait;
use clap::Parser;
use self_update::{
    backends::github::Update, cargo_crate_version, update::ReleaseUpdate, version::bump_is_greater,
};
use std::path::PathBuf;

pub const TARGET_REVELA_TAG: &str = "v1.0.0-rc2";

/// Update Revela, the binary used for decompilation.
#[derive(Debug, Parser)]
pub struct RevelaUpdateTool {
    /// The owner of the repo to download the binary from.
    #[clap(long, default_value = "verichains")]
    repo_owner: String,

    /// The name of the repo to download the binary from.
    #[clap(long, default_value = "revela")]
    repo_name: String,

    /// The tag we target to install.
    #[clap(long, default_value = TARGET_REVELA_TAG)]
    target_tag: String,

    /// Where to install the binary. Make sure this directory is on your PATH.
    #[clap(long)]
    install_dir: Option<PathBuf>,
}

impl BinaryUpdater for RevelaUpdateTool {
    fn pretty_name(&self) -> &'static str {
        "Revela"
    }

    /// Return information about whether an update is required.
    fn get_update_info(&self) -> Result<UpdateRequiredInfo> {
        // todo do this properly.
        let current_version = "1.0.0-rc1";

        // Return early if we're up to date already.
        let update_required = bump_is_greater(current_version, &self.target_tag.replace("v", ""))
            .context("Failed to compare current and latest CLI versions")?;

        Ok(UpdateRequiredInfo {
            update_required,
            current_version: current_version.to_string(),
            target_version: self.target_tag.to_string(),
            target_version_tag: self.target_tag.to_string(),
        })
    }

    fn build_self_updater(&self, info: &UpdateRequiredInfo) -> Result<Box<dyn ReleaseUpdate>> {
        let arch_str = get_arch();

        // Determine the target we should download based on how the CLI itself was built.
        let build_info = cli_build_information();
        // TODO: Make this smarter. I wish we could get the OS and the arch separately.
        let target = match build_info.get(BUILD_OS).context("Failed to determine build info of current CLI")?.as_str() {
            "linux-aarch64" | "linux-x86_64" => "unknown-linux-gnu",
            "macos-aarch64" | "macos-x86" => "apple-darwin",
            "windows-x86_64" => "pc-windows-gnu",
            wildcard => bail!("Self-updating is not supported on your OS right now, please download the binary manually: {}", wildcard),
        };

        let target = format!("{}-{}", arch_str, target);

        let install_dir = match self.install_dir.clone() {
            Some(dir) => dir,
            None => {
                let mut install_dir = std::env::current_exe()
                    .context("Failed to determine current executable path")?;
                install_dir.pop();
                install_dir
            },
        };

        // Build a new configuration that will direct the library to download the
        // binary with the target version tag and target that we determined above.
        Ok(Update::configure()
            .bin_install_dir(install_dir)
            // todo why is the "aptos" binary still being replaced?
            .bin_name("revela")
            .repo_owner(&self.repo_owner)
            .repo_name(&self.repo_name)
            // TODO use the real current version
            .current_version(&info.current_version)
            .target_version_tag(&info.target_version_tag)
            .target(&target)
            .build()
            .map_err(|e| anyhow!("Failed to build self-update configuration: {:#}", e))?)
    }
}

#[async_trait]
impl CliCommand<String> for RevelaUpdateTool {
    fn command_name(&self) -> &'static str {
        "UpdateRevela"
    }

    async fn execute(self) -> CliTypedResult<String> {
        tokio::task::spawn_blocking(move || self.update())
            .await
            .context("Failed to self-update Revela")?
    }
}

#[cfg(target_arch = "x86_64")]
fn get_arch() -> &'static str {
    "x86_64"
}

#[cfg(target_arch = "aarch64")]
fn get_arch() -> &'static str {
    "aarch64"
}

#[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
fn get_arch() -> &'static str {
    unimplemented!("Self-updating is not supported on your CPU architecture right now, please download the binary manually")
}
