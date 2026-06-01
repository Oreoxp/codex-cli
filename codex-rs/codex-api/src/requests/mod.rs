pub(crate) mod headers;
pub(crate) mod responses;

pub use responses::Compression;
pub(crate) use responses::attach_item_ids;
// OpenCrab step-22 fork: promoted from pub(crate) to pub so
// `codex_model_provider::provider::ConfiguredModelProvider::capabilities`
// can reuse the same dashscope detection (no second detector to drift).
pub use responses::provider_needs_dashscope_tool_output_rewrite;
pub(crate) use responses::rewrite_tool_outputs_as_user_messages_for_dashscope;
