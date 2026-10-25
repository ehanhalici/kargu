//! One physical exchange per grant. No budget/circuit/retry state is written here.

use super::{Completion, Event, EventValue, Outcome, publish_body};
use crate::{
    api::{ApiError, HttpRequest, resilience::RetryEntropy},
    application::budget::ObservedUsage,
    domain::Deadline,
};
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub(super) async fn attempt(
    id: super::RpcId,
    arguments: Arc<HttpRequest>,
    sender: mpsc::Sender<Event>,
    cancel: CancellationToken,
    deadline: Option<Deadline>,
    page_bytes: usize,
    observe_entropy: bool,
) -> (super::RpcId, Completion) {
    let event_id = id.clone();
    let event_sender = sender.clone();
    let exchange = crate::api::execute_captured(
        arguments.as_ref(),
        move |value| {
            let sender = event_sender.clone();
            let id = event_id.clone();
            async move {
                sender
                    .send(Event {
                        id,
                        value: EventValue::Delta(value),
                    })
                    .await
                    .map_err(|_| ApiError::Cancelled)
            }
        },
        cancel.clone(),
    );
    let result = if let Some(deadline) = deadline {
        tokio::select! {
            biased;
            _ = deadline.elapsed() => Err(ApiError::RunDeadline),
            result = exchange => result,
        }
    } else {
        exchange.await
    };
    let (result, usage) = match result {
        Ok(value) => match ObservedUsage::try_from(&value) {
            Ok(usage) => (Ok(value), usage),
            Err(_) => (Err(ApiError::Protocol), ObservedUsage::default()),
        },
        Err(error) => (Err(error), ObservedUsage::default()),
    };
    let entropy = (observe_entropy && matches!(&result, Err(ApiError::Http { .. })))
        .then(RetryEntropy::capture);
    let result = match result {
        Ok(value) => {
            let publish = publish_body(&sender, &id, value, &cancel, page_bytes);
            if let Some(deadline) = deadline {
                tokio::select! {
                    biased;
                    _ = deadline.elapsed() => Err(ApiError::RunDeadline),
                    result = publish => result,
                }
            } else {
                publish.await
            }
        }
        Err(error) => Err(error),
    };
    (
        id,
        Completion::Attempt(Outcome {
            result,
            usage,
            entropy,
        }),
    )
}
