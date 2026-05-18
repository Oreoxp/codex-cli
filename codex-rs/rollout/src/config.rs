use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;

pub trait RolloutConfigView {
    fn codex_home(&self) -> &Path;
    fn sqlite_home(&self) -> &Path;
    fn cwd(&self) -> &Path;
    fn model_provider_id(&self) -> &str;
    fn generate_memories(&self) -> bool;

    /// OpenCrab Phase 4 Step 8 — optional override for the rollout
    /// directory. When `Some`, the rollout file is written directly
    /// under this path (no `YYYY/MM/DD` subdivision); when `None`, the
    /// classic `codex_home/sessions/YYYY/MM/DD/` behavior is used.
    ///
    /// Default impl returns `None` so every existing
    /// `RolloutConfigView` implementor (including external code) keeps
    /// its upstream behavior without source changes.
    fn team_session_dir(&self) -> Option<&Path> {
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RolloutConfig {
    pub codex_home: PathBuf,
    pub sqlite_home: PathBuf,
    pub cwd: PathBuf,
    pub model_provider_id: String,
    pub generate_memories: bool,
    /// OpenCrab Step 8 — see `RolloutConfigView::team_session_dir`.
    pub team_session_dir: Option<PathBuf>,
}

pub type Config = RolloutConfig;

impl RolloutConfig {
    pub fn from_view(view: &impl RolloutConfigView) -> Self {
        Self {
            codex_home: view.codex_home().to_path_buf(),
            sqlite_home: view.sqlite_home().to_path_buf(),
            cwd: view.cwd().to_path_buf(),
            model_provider_id: view.model_provider_id().to_string(),
            generate_memories: view.generate_memories(),
            team_session_dir: view.team_session_dir().map(Path::to_path_buf),
        }
    }
}

impl RolloutConfigView for RolloutConfig {
    fn codex_home(&self) -> &Path {
        self.codex_home.as_path()
    }

    fn sqlite_home(&self) -> &Path {
        self.sqlite_home.as_path()
    }

    fn cwd(&self) -> &Path {
        self.cwd.as_path()
    }

    fn model_provider_id(&self) -> &str {
        self.model_provider_id.as_str()
    }

    fn generate_memories(&self) -> bool {
        self.generate_memories
    }

    fn team_session_dir(&self) -> Option<&Path> {
        self.team_session_dir.as_deref()
    }
}

impl<T: RolloutConfigView + ?Sized> RolloutConfigView for &T {
    fn codex_home(&self) -> &Path {
        (*self).codex_home()
    }

    fn sqlite_home(&self) -> &Path {
        (*self).sqlite_home()
    }

    fn cwd(&self) -> &Path {
        (*self).cwd()
    }

    fn model_provider_id(&self) -> &str {
        (*self).model_provider_id()
    }

    fn generate_memories(&self) -> bool {
        (*self).generate_memories()
    }

    fn team_session_dir(&self) -> Option<&Path> {
        (*self).team_session_dir()
    }
}

impl<T: RolloutConfigView + ?Sized> RolloutConfigView for Arc<T> {
    fn codex_home(&self) -> &Path {
        self.as_ref().codex_home()
    }

    fn sqlite_home(&self) -> &Path {
        self.as_ref().sqlite_home()
    }

    fn cwd(&self) -> &Path {
        self.as_ref().cwd()
    }

    fn model_provider_id(&self) -> &str {
        self.as_ref().model_provider_id()
    }

    fn generate_memories(&self) -> bool {
        self.as_ref().generate_memories()
    }

    fn team_session_dir(&self) -> Option<&Path> {
        self.as_ref().team_session_dir()
    }
}
