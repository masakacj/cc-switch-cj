#!/usr/bin/env python3
"""Apply the Claude Code VS Code `redacted_thinking` compatibility fix.

This intentionally performs narrow, idempotent source rewrites so the patch can be
re-applied after syncing this fork with upstream CC Switch.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str, marker: str) -> bool:
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"already patched: {path.relative_to(ROOT)}")
        return False
    count = text.count(old)
    if count != 1:
        raise RuntimeError(
            f"expected exactly one upstream pattern in {path.relative_to(ROOT)}, found {count}; "
            "upstream likely changed and this compatibility patch needs review"
        )
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"patched: {path.relative_to(ROOT)}")
    return True


reasoning = ROOT / "src-tauri/src/proxy/providers/reasoning_bridge.rs"
old_reasoning = '''    if has_encrypted_content {
        let envelope = encode_openai_reasoning_item(item)?;
        if text.is_empty() {
            return Some(json!({
                "type": "redacted_thinking",
                "data": envelope
            }));
        }
        return Some(json!({
            "type": "thinking",
            "thinking": text,
            "signature": envelope
        }));
    }
'''
new_reasoning = '''    if has_encrypted_content {
        let envelope = encode_openai_reasoning_item(item)?;
        // Claude Code's VS Code extension does not render redacted_thinking.
        // Preserve the opaque Responses reasoning item in signature instead.
        return Some(json!({
            "type": "thinking",
            "thinking": text,
            "signature": envelope
        }));
    }
'''
replace_once(
    reasoning,
    old_reasoning,
    new_reasoning,
    "Claude Code's VS Code extension does not render redacted_thinking",
)

# Keep the upstream unit test aligned with the new wire representation while
# explicitly verifying that the opaque reasoning envelope still round-trips.
reasoning_text = reasoning.read_text(encoding="utf-8")
old_test = '''    #[test]
    fn encrypted_item_without_summary_uses_redacted_thinking() {
        let item = json!({
            "id": "rs_2",
            "type": "reasoning",
            "summary": [],
            "encrypted_content": "opaque"
        });
        let block = anthropic_block_from_openai_reasoning_item(&item).unwrap();
        assert_eq!(block["type"], "redacted_thinking");
        assert_eq!(
            openai_reasoning_item_from_anthropic_block(&block),
            Some(item)
        );
    }
'''
new_test = '''    #[test]
    fn encrypted_item_without_summary_uses_empty_thinking_signature() {
        let item = json!({
            "id": "rs_2",
            "type": "reasoning",
            "summary": [],
            "encrypted_content": "opaque",
            "future_field": {"preserved": true}
        });
        let block = anthropic_block_from_openai_reasoning_item(&item).unwrap();
        assert_eq!(block["type"], "thinking");
        assert_eq!(block["thinking"], "");
        assert!(block.get("data").is_none());
        assert!(block["signature"]
            .as_str()
            .is_some_and(|value| value.starts_with(OPENAI_REASONING_ITEM_PREFIX)));
        assert_eq!(
            openai_reasoning_item_from_anthropic_block(&block),
            Some(item)
        );
    }
'''
if "fn encrypted_item_without_summary_uses_empty_thinking_signature()" not in reasoning_text:
    count = reasoning_text.count(old_test)
    if count != 1:
        raise RuntimeError(f"expected one reasoning bridge regression test, found {count}")
    reasoning.write_text(reasoning_text.replace(old_test, new_test, 1), encoding="utf-8")
    print("updated reasoning bridge regression test")
else:
    print("reasoning bridge regression test already updated")

streaming = ROOT / "src-tauri/src/proxy/providers/streaming_responses.rs"
old_stream = '''                                                } else {
                                                    let start_event = json!({
                                                        "type": "content_block_start",
                                                        "index": index,
                                                        "content_block": {
                                                            "type": "redacted_thinking",
                                                            "data": envelope
                                                        }
                                                    });
                                                    let start_sse = format!("event: content_block_start\\ndata: {}\\n\\n",
                                                        serde_json::to_string(&start_event).unwrap_or_default());
                                                    yield Ok(Bytes::from(start_sse));
                                                    open_indices.insert(index);
                                                }
'''
new_stream = '''                                                } else {
                                                    // VS Code Claude Code cannot render redacted_thinking.
                                                    // Start an empty thinking block and carry the opaque item
                                                    // through the normal Anthropic signature delta instead.
                                                    let start_event = json!({
                                                        "type": "content_block_start",
                                                        "index": index,
                                                        "content_block": {"type": "thinking", "thinking": ""}
                                                    });
                                                    let start_sse = format!("event: content_block_start\\ndata: {}\\n\\n",
                                                        serde_json::to_string(&start_event).unwrap_or_default());
                                                    yield Ok(Bytes::from(start_sse));
                                                    open_indices.insert(index);

                                                    let signature_event = json!({
                                                        "type": "content_block_delta",
                                                        "index": index,
                                                        "delta": {
                                                            "type": "signature_delta",
                                                            "signature": envelope
                                                        }
                                                    });
                                                    let signature_sse = format!("event: content_block_delta\\ndata: {}\\n\\n",
                                                        serde_json::to_string(&signature_event).unwrap_or_default());
                                                    yield Ok(Bytes::from(signature_sse));
                                                }
'''
replace_once(
    streaming,
    old_stream,
    new_stream,
    "VS Code Claude Code cannot render redacted_thinking",
)

print("VSCode redacted_thinking compatibility patch is applied.")
