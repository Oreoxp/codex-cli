use super::LocalThreadStore;
use crate::CreateThreadParams;
use crate::ThreadStoreError;
use crate::ThreadStoreResult;
use codex_protocol::protocol::ThreadMemoryMode;
use codex_rollout::RolloutConfig;
use codex_rollout::RolloutRecorder;
use codex_rollout::RolloutRecorderParams;

pub(super) async fn create_thread(
    store: &LocalThreadStore,
    params: CreateThreadParams,
) -> ThreadStoreResult<RolloutRecorder> {
    let cwd = params
        .metadata
        .cwd
        .clone()
        .ok_or_else(|| ThreadStoreError::InvalidRequest {
            message: "local thread store requires a cwd".to_string(),
        })?;
    let config = RolloutConfig {
        codex_home: store.config.codex_home.clone(),
        sqlite_home: store.config.sqlite_home.clone(),
        cwd,
        model_provider_id: params.metadata.model_provider.clone(),
        generate_memories: matches!(params.metadata.memory_mode, ThreadMemoryMode::Enabled),
        // OpenCrab Phase 4 Step 8 — honor the per-thread rollout dir
        // override forwarded on `CreateThreadParams`. The app-server's
        // `thread/start` path routes new threads through this local
        // store, so the override has to be applied *here* (not just in
        // the app-server `Config`); `None` keeps the upstream
        // `codex_home/sessions/YYYY/MM/DD/` layout.
        team_session_dir: params.team_session_dir.clone(),
    };
    let recorder = RolloutRecorder::new(
        &config,
        RolloutRecorderParams::new(
            params.thread_id,
            params.forked_from_id,
            params.parent_thread_id,
            params.source,
            params.thread_source,
            params.base_instructions,
            params.dynamic_tools,
        ),
    )
    .await
    .map_err(|err| ThreadStoreError::Internal {
        message: format!("failed to initialize local thread recorder: {err}"),
    })?;

    Ok(recorder)
}
