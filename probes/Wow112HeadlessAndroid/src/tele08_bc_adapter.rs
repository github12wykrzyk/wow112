use crate::tele08_whisper_parser::{request_fingerprint, WhisperClassification, WhisperIntent};
use tele08_request_queue::SummonRequest;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AdmissionRejection {
    NonQueueableIntent(WhisperIntent),
    MissingDestination,
}

pub fn classification_to_request(
    classification: &WhisperClassification,
) -> Result<SummonRequest, AdmissionRejection> {
    match classification.intent {
        WhisperIntent::SummonRequest
        | WhisperIntent::InviteRequest
        | WhisperIntent::GenericPositive => {}
        ref other => return Err(AdmissionRejection::NonQueueableIntent(other.clone())),
    }

    let destination = classification
        .destination
        .as_ref()
        .ok_or(AdmissionRejection::MissingDestination)?;

    let fingerprint = request_fingerprint(classification);
    let request_id = format!("{fingerprint}:{}", classification.timestamp_ms);
    let mut request = SummonRequest::new(
        request_id,
        classification.sender.clone(),
        destination.0.clone(),
        classification.timestamp_ms,
    );

    request
        .metadata
        .insert("parser_fingerprint".into(), fingerprint);
    request.metadata.insert(
        "parser_intent".into(),
        intent_name(&classification.intent).into(),
    );
    request.metadata.insert(
        "parser_confidence".into(),
        classification.confidence.to_string(),
    );
    request.metadata.insert(
        "parser_normalized_text".into(),
        classification.normalized_text.clone(),
    );
    request
        .metadata
        .insert("parser_reason".into(), classification.reason.clone());
    request
        .metadata
        .insert("parser_signals".into(), classification.signals.join("|"));

    Ok(request)
}

fn intent_name(intent: &WhisperIntent) -> &'static str {
    match intent {
        WhisperIntent::SummonRequest => "SummonRequest",
        WhisperIntent::InviteRequest => "InviteRequest",
        WhisperIntent::PresenceReady => "PresenceReady",
        WhisperIntent::DestinationQuery => "DestinationQuery",
        WhisperIntent::GenericPositive => "GenericPositive",
        WhisperIntent::CompetitionMessage => "CompetitionMessage",
        WhisperIntent::Irrelevant => "Irrelevant",
        WhisperIntent::Unknown => "Unknown",
    }
}
