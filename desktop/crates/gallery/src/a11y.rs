//! The AccessKit check: walks the tree GPUI last sent to the platform
//! (`Window::debug_a11y_tree_json`) and requires every control to have a
//! role and a non-empty label, and every message to be a labelled Article.

use serde::Serialize;
use serde_json::Value;

/// Roles a VoiceOver user can operate.
pub const CONTROL_ROLES: &[&str] = &[
    "Button",
    "CheckBox",
    "Switch",
    "RadioButton",
    "TextInput",
    "MultilineTextInput",
    "SearchInput",
    "PasswordInput",
    "ComboBox",
    "EditableComboBox",
    "Link",
    "MenuItem",
    "MenuItemCheckBox",
    "MenuItemRadio",
    "Tab",
    "ListBoxOption",
    "Slider",
    "SpinButton",
    "TreeItem",
    "DisclosureTriangle",
];

/// Roles that mean "no semantics" (a clickable one of these is a bug).
const GENERIC_ROLES: &[&str] = &["GenericContainer", "Unknown", "Group"];

#[derive(Serialize, Debug, Clone)]
pub struct Control {
    pub role: String,
    pub label: String,
}

#[derive(Serialize, Debug)]
pub struct Report {
    pub screen: String,
    pub nodes: usize,
    pub controls: Vec<Control>,
    pub articles: Vec<String>,
    pub failures: Vec<String>,
    pub error: Option<String>,
}

impl Report {
    pub fn error(screen: &str, message: &str) -> Self {
        Self {
            screen: screen.to_string(),
            nodes: 0,
            controls: vec![],
            articles: vec![],
            failures: vec![],
            error: Some(message.to_string()),
        }
    }

    pub fn passed(&self) -> bool {
        self.error.is_none() && self.failures.is_empty() && !self.controls.is_empty()
    }
}

/// Checks the debug JSON of one window's AccessKit tree.
pub fn check(screen: &str, json: &str) -> Report {
    let doc: Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(e) => return Report::error(screen, &format!("bad tree JSON: {e}")),
    };
    let Some(nodes) = doc.get("nodes").and_then(Value::as_object) else {
        return Report::error(screen, "tree JSON has no nodes");
    };
    let mut report = Report {
        screen: screen.to_string(),
        nodes: nodes.len(),
        controls: vec![],
        articles: vec![],
        failures: vec![],
        error: None,
    };
    for (key, node) in nodes {
        let aria = node.get("aria").cloned().unwrap_or(Value::Null);
        let role = aria
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let label = aria
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        let clickable = aria
            .get("on_action")
            .and_then(Value::as_array)
            .is_some_and(|a| a.iter().any(|v| v.as_str() == Some("Click")));
        let element = node
            .get("element_id")
            .and_then(Value::as_str)
            .unwrap_or(key.as_str())
            .to_string();
        if role == "Article" {
            if label.is_empty() {
                report
                    .failures
                    .push(format!("article {element} has no label"));
            } else {
                report.articles.push(label.chars().take(80).collect());
            }
            continue;
        }
        let is_control = CONTROL_ROLES.contains(&role.as_str());
        if clickable && !is_control && GENERIC_ROLES.contains(&role.as_str()) {
            report
                .failures
                .push(format!("clickable {element} has no control role ({role})"));
        }
        if is_control {
            if label.is_empty() {
                report
                    .failures
                    .push(format!("{role} {element} has no label"));
            }
            report.controls.push(Control { role, label });
        }
    }
    report.controls.sort_by(|a, b| a.label.cmp(&b.label));
    report
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flags_unlabelled_controls_and_roleless_clickables() {
        let json = r#"{"nodes":{
            "a":{"aria":{"role":"Button","label":"Send","on_action":["Click"]}},
            "b":{"aria":{"role":"Button","on_action":["Click"]},"element_id":"mystery"},
            "c":{"aria":{"role":"GenericContainer","on_action":["Click"]},"element_id":"div"},
            "d":{"aria":{"role":"Article","label":"You: hello"}}
        }}"#;
        let r = check("t", json);
        assert_eq!(r.controls.len(), 2);
        assert_eq!(r.articles, vec!["You: hello".to_string()]);
        assert_eq!(r.failures.len(), 2, "{:?}", r.failures);
        assert!(!r.passed());
    }

    #[test]
    fn passes_a_clean_tree() {
        let json = r#"{"nodes":{"a":{"aria":{"role":"Button","label":"Send"}}}}"#;
        assert!(check("t", json).passed());
    }
}
