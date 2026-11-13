//! The Rust types against the Dart protocol's goldens.
//!
//! `packages/conduit_protocol/tool/dump_goldens.dart` writes every Dart
//! fixture to `goldens/<name>.json`, `manifest.json` (fixture -> DTO type)
//! and `specs.json` (the method and event tables as the daemon has them).
//! Each golden must decode into its Rust type and encode back to the same
//! JSON value, and the generated tables must match the daemon's.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use conduit_protocol::conformance::{TYPE_NAMES, roundtrip};
use conduit_protocol::{
    APP_ORIGIN, EVENT_NOTIFICATION, EVENTS, ErrorCode, ErrorObject, Event, EventEnvelope, METHODS,
    Message, NoParams, PROTOCOL_VERSION, Request, Response, RpcError, RpcMethod, SUBPROTOCOL,
    ServerReachability, WindowKind, methods, routes, subprotocols,
};
use serde_json::{Value, json};

fn goldens_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../packages/conduit_protocol/goldens")
}

fn read_json(name: &str) -> Value {
    let path = goldens_dir().join(name);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// Fixture name -> DTO type name.
fn manifest() -> BTreeMap<String, String> {
    serde_json::from_value(read_json("manifest.json")).expect("manifest.json")
}

fn specs() -> Value {
    read_json("specs.json")
}

/// The first golden of `type_name`.
fn golden_of(type_name: &str) -> Value {
    let (fixture, _) = manifest()
        .into_iter()
        .find(|(_, ty)| ty == type_name)
        .unwrap_or_else(|| panic!("no golden of type {type_name}"));
    read_json(&format!("{fixture}.json"))
}

#[test]
fn every_golden_round_trips_through_its_rust_type() {
    let manifest = manifest();
    assert!(manifest.len() > 200, "only {} goldens", manifest.len());
    let mut failures = Vec::new();
    for (fixture, type_name) in &manifest {
        let golden = read_json(&format!("{fixture}.json"));
        match roundtrip(type_name, &golden) {
            None => failures.push(format!("{fixture}: no Rust type {type_name}")),
            Some(Err(error)) => failures.push(format!("{fixture} ({type_name}): {error}")),
            Some(Ok(encoded)) if encoded != golden => failures.push(format!(
                "{fixture} ({type_name}): re-encoded differently\n  golden:  {golden}\n  encoded: {encoded}"
            )),
            Some(Ok(_)) => {}
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn every_rust_type_has_a_golden() {
    let covered: Vec<String> = manifest().into_values().collect();
    let missing: Vec<&&str> = TYPE_NAMES
        .iter()
        .filter(|name| !covered.iter().any(|c| c == **name))
        .collect();
    assert!(missing.is_empty(), "no golden for {missing:?}");
}

#[test]
fn the_method_table_matches_the_daemons() {
    let specs = specs();
    let expected: Vec<(String, Option<String>, Option<String>)> =
        serde_json::from_value::<Vec<BTreeMap<String, Option<String>>>>(specs["methods"].clone())
            .unwrap()
            .into_iter()
            .map(|m| {
                (
                    m["name"].clone().unwrap(),
                    m["params"].clone(),
                    m["result"].clone(),
                )
            })
            .collect();
    let actual: Vec<(String, Option<String>, Option<String>)> = METHODS
        .iter()
        .map(|m| {
            (
                m.name.to_owned(),
                m.params.map(str::to_owned),
                m.result.map(str::to_owned),
            )
        })
        .collect();
    assert_eq!(actual, expected);
}

#[test]
fn every_method_in_the_spec_has_types() {
    // Each method's params and result are generated types with goldens, so
    // the conformance test above covers what every call sends and receives.
    for method in METHODS {
        for type_name in method.params.iter().chain(method.result.iter()) {
            assert!(
                TYPE_NAMES.contains(type_name),
                "{}: {type_name} is not a generated type",
                method.name
            );
            let golden = golden_of(type_name);
            assert!(
                matches!(roundtrip(type_name, &golden), Some(Ok(_))),
                "{}: {type_name}",
                method.name
            );
        }
    }
}

#[test]
fn the_event_table_matches_the_daemons() {
    let expected: Vec<(String, Option<String>, bool)> = specs()["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| {
            (
                e["name"].as_str().unwrap().to_owned(),
                e["payload"].as_str().map(str::to_owned),
                e["scoped"].as_bool().unwrap(),
            )
        })
        .collect();
    let actual: Vec<(String, Option<String>, bool)> = EVENTS
        .iter()
        .map(|e| (e.name.to_owned(), e.payload.map(str::to_owned), e.scoped))
        .collect();
    assert_eq!(actual, expected);
}

#[test]
fn every_event_round_trips_through_the_event_enum() {
    for spec in EVENTS {
        let payload = spec.payload.map_or_else(|| json!({}), golden_of);
        let mut frame =
            json!({"event": spec.name, "seq": 9007199254740991_i64, "payload": payload});
        if spec.scoped {
            frame["scope"] = json!("chat-1");
        }
        let envelope: EventEnvelope = serde_json::from_value(frame.clone()).unwrap();
        let event =
            Event::from_envelope(&envelope).unwrap_or_else(|e| panic!("{}: {e}", spec.name));
        assert_eq!(event.name(), spec.name);
        assert!(
            !matches!(event, Event::Unknown { .. }),
            "{} decoded as Unknown",
            spec.name
        );
        assert_eq!(event.is_scoped(), spec.scoped, "{}", spec.name);
        assert_eq!(event.payload().unwrap(), payload, "{}", spec.name);

        let again = event
            .into_envelope(envelope.seq, envelope.scope.clone())
            .unwrap();
        assert_eq!(
            serde_json::to_value(&again).unwrap(),
            frame,
            "{}",
            spec.name
        );
    }
}

#[test]
fn an_unknown_event_is_kept_as_it_came() {
    let frame = json!({"event": "future.thing", "seq": 4, "payload": {"answer": [42]}});
    let envelope: EventEnvelope = serde_json::from_value(frame.clone()).unwrap();
    let event = Event::try_from(envelope).unwrap();
    assert_eq!(
        event,
        Event::Unknown {
            name: "future.thing".into(),
            payload: json!({"answer": [42]}),
        }
    );
    assert!(!event.is_scoped());
    let again = event.into_envelope(4, None).unwrap();
    assert_eq!(serde_json::to_value(again).unwrap(), frame);
}

#[test]
fn a_known_event_with_a_wrong_payload_is_an_error() {
    assert!(Event::decode("turn.delta", json!({"text": 1})).is_err());
    // Without a payload DTO, whatever comes is ignored.
    assert_eq!(
        Event::decode("models.changed", json!({"x": 1})).unwrap(),
        Event::ModelsChanged
    );
}

#[test]
fn an_event_arrives_as_the_event_notification() {
    let frame = format!(
        r#"{{"jsonrpc":"2.0","method":"{EVENT_NOTIFICATION}","params":{{"event":"ui.settled","seq":1,"payload":{{"requestId":"r1"}}}}}}"#
    );
    let Message::Request(request) = serde_json::from_str(&frame).unwrap() else {
        panic!("not a request");
    };
    let event = Event::try_from(request.event().unwrap().unwrap()).unwrap();
    let Event::UiSettled(settled) = event else {
        panic!("{event:?}");
    };
    assert_eq!(settled.request_id, "r1");
}

#[test]
fn unknown_enum_values_decode_as_unknown() {
    assert_eq!(
        serde_json::from_value::<WindowKind>(json!("floating")).unwrap(),
        WindowKind::Unknown
    );
    assert_eq!(
        serde_json::from_value::<WindowKind>(json!("quickAsk")).unwrap(),
        WindowKind::QuickAsk
    );
    // An enum with its own `unknown` uses it as the fallback too.
    for value in ["unknown", "somethingNew"] {
        assert_eq!(
            serde_json::from_value::<ServerReachability>(json!(value)).unwrap(),
            ServerReachability::Unknown
        );
    }
    assert_eq!(
        serde_json::to_value(ServerReachability::NotOpenWebUi).unwrap(),
        json!("notOpenWebUi")
    );
}

#[test]
fn calls_are_typed_by_their_method() {
    let request = Request::call::<methods::SystemPing>(1, &NoParams).unwrap();
    assert_eq!(
        serde_json::to_value(&request).unwrap(),
        json!({"jsonrpc": "2.0", "id": 1, "method": "system.ping", "params": {}})
    );
    assert_eq!(<methods::ChatsTagsAll as RpcMethod>::NAME, "chats.tags.all");

    let reply: Response = serde_json::from_str(
        r#"{"jsonrpc":"2.0","id":1,"result":{"uptimeMs":5,"serverTimeMs":6}}"#,
    )
    .unwrap();
    let pong = reply.into_result::<methods::SystemPing>().unwrap();
    assert_eq!((pong.uptime_ms, pong.server_time_ms), (5, 6));
}

#[test]
fn a_conduit_error_comes_back_as_it_was_sent() {
    // As json_rpc_2 sends it: `data` with a `request` key added.
    let frame = json!({
        "jsonrpc": "2.0",
        "id": 3,
        "error": {
            "code": -32000,
            "message": "upstream returned 503",
            "data": {
                "code": "net.serverError",
                "args": {"status": "503"},
                "debugMessage": "upstream returned 503",
                "retryable": true,
                "request": {"method": "chats.list", "id": 3}
            }
        }
    });
    let response: Response = serde_json::from_value(frame).unwrap();
    let error = response.into_result::<methods::ChatsList>().unwrap_err();
    assert_eq!(error.code, ErrorCode::ServerError);
    assert_eq!(error.args["status"], "503");
    assert!(error.retryable);
    assert_eq!(
        error.to_error_object().code,
        specs()["rpcErrorCode"].as_i64().unwrap()
    );

    let unknown = RpcError::from_error_object(&ErrorObject {
        code: -32000,
        message: String::new(),
        data: Some(json!({"code": "future.code"})),
    });
    assert_eq!(unknown.code, ErrorCode::Other("future.code".into()));
    assert_eq!(unknown.code.as_str(), "future.code");

    let standard = RpcError::from_error_object(&ErrorObject {
        code: -32601,
        message: "Unknown method".into(),
        data: None,
    });
    assert_eq!(standard.code, ErrorCode::MethodNotFound);
    assert_eq!(standard.debug_message.as_deref(), Some("Unknown method"));
}

#[test]
fn transport_constants_match_the_dart_ones() {
    let specs = specs();
    assert_eq!(PROTOCOL_VERSION, specs["protocolVersion"]);
    assert_eq!(APP_ORIGIN, specs["appOrigin"]);
    assert_eq!(SUBPROTOCOL, specs["subprotocol"]);
    assert_eq!(EVENT_NOTIFICATION, specs["eventNotification"]);

    let example = &specs["subprotocolsExample"];
    let token = example["sessionToken"].as_str().unwrap();
    assert_eq!(json!(subprotocols(token)), example["protocols"]);

    let routes_json = &specs["httpRoutes"];
    assert_eq!(routes::RPC, routes_json["rpc"]);
    assert_eq!(routes::UPLOAD, routes_json["upload"]);
    assert_eq!(routes::TRANSCRIBE, routes_json["transcribe"]);
    assert_eq!(routes::TERMINAL_UPLOAD, routes_json["terminalUpload"]);
    assert_eq!(routes::file("{serverId}", "{fileId}"), routes_json["file"]);
    assert_eq!(routes::tts("{jobId}"), routes_json["tts"]);
    assert_eq!(routes::terminal("{handle}"), routes_json["terminal"]);
}
