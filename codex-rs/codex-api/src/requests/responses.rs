use codex_protocol::models::ResponseItem;
use serde_json::Map;
use serde_json::Value;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Compression {
    #[default]
    None,
    Zstd,
}

pub(crate) fn attach_item_ids(payload_json: &mut Value, original_items: &[ResponseItem]) {
    let Some(input_value) = payload_json.get_mut("input") else {
        return;
    };
    let Value::Array(items) = input_value else {
        return;
    };

    for (value, item) in items.iter_mut().zip(original_items.iter()) {
        if let ResponseItem::Reasoning { id, .. }
        | ResponseItem::Message { id: Some(id), .. }
        | ResponseItem::WebSearchCall { id: Some(id), .. }
        | ResponseItem::FunctionCall { id: Some(id), .. }
        | ResponseItem::ToolSearchCall { id: Some(id), .. }
        | ResponseItem::LocalShellCall { id: Some(id), .. }
        | ResponseItem::CustomToolCall { id: Some(id), .. } = item
        {
            if id.is_empty() {
                continue;
            }

            if let Some(obj) = value.as_object_mut() {
                obj.insert("id".to_string(), Value::String(id.clone()));
            }
        }
    }
}

pub(crate) fn rewrite_tool_outputs_as_user_messages_for_dashscope(payload_json: &mut Value) {
    let Some(Value::Array(items)) = payload_json.get_mut("input") else {
        return;
    };

    for item in items {
        let Some(obj) = item.as_object() else {
            continue;
        };
        let item_type = obj.get("type").and_then(Value::as_str);
        let is_tool_output = matches!(
            item_type,
            Some("function_call_output")
                | Some("custom_tool_call_output")
                | Some("mcp_tool_call_output")
                | Some("tool_search_output")
        );
        if !is_tool_output {
            continue;
        }

        let call_id = obj
            .get("call_id")
            .and_then(Value::as_str)
            .unwrap_or("unknown_call");
        let output_text = tool_output_value_to_text(
            obj.get("output")
                .or_else(|| obj.get("execution"))
                .or_else(|| obj.get("tools")),
        );

        let mut replacement = Map::new();
        replacement.insert("role".to_string(), Value::String("user".to_string()));
        replacement.insert(
            "content".to_string(),
            Value::String(format!("Tool result for {call_id}:\n{output_text}")),
        );
        *item = Value::Object(replacement);
    }
}

fn tool_output_value_to_text(value: Option<&Value>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    if let Some(text) = value.as_str() {
        return text.to_string();
    }
    if let Some(items) = value.as_array() {
        let text = items
            .iter()
            .filter_map(|item| {
                item.get("text")
                    .and_then(Value::as_str)
                    .or_else(|| item.get("input_text").and_then(Value::as_str))
            })
            .filter(|text| !text.trim().is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        if !text.is_empty() {
            return text;
        }
    }
    value.to_string()
}

pub(crate) fn provider_needs_dashscope_tool_output_rewrite(base_url: &str) -> bool {
    let normalized = base_url.to_ascii_lowercase();
    normalized.contains("dashscope.aliyuncs.com")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rewrites_function_call_output_as_user_message_for_dashscope() {
        let mut payload = json!({
            "input": [
                {"role": "user", "content": "hi"},
                {"type": "function_call_output", "call_id": "call_1", "output": "ok"}
            ]
        });

        rewrite_tool_outputs_as_user_messages_for_dashscope(&mut payload);

        assert_eq!(
            payload["input"][1],
            json!({
                "role": "user",
                "content": "Tool result for call_1:\nok"
            })
        );
    }

    #[test]
    fn dashscope_provider_detection_uses_base_url() {
        assert!(provider_needs_dashscope_tool_output_rewrite(
            "https://dashscope.aliyuncs.com/compatible-mode/v1"
        ));
        assert!(!provider_needs_dashscope_tool_output_rewrite(
            "https://api.openai.com/v1"
        ));
    }
}
