//! One physical exchange per grant. No budget/circuit/retry state is written here.

use super::{Completion, Event, EventValue, Outcome, publish_body};
use crate::{
    api::{ApiError, HttpRequest, resilience::RetryEntropy},
    application::budget::ObservedUsage,
    domain::{ApiPageBytes, Deadline},
};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub(super) enum ResponseExpectation {
    Raw,
    Model,
}
pub(super) struct Attempt {
    pub id: super::RpcId,
    pub arguments: Arc<HttpRequest>,
    pub sender: mpsc::Sender<Event>,
    pub cancel: CancellationToken,
    pub deadline: Option<Deadline>,
    pub page_bytes: ApiPageBytes,
    pub observe_entropy: bool,
    pub expectation: ResponseExpectation,
}
impl Attempt {
    pub async fn run(self) -> (super::RpcId, Completion) {
        let result = self.exchange().await.and_then(|value| self.observe(value));
        let (result, usage) = match result {
            Ok((value, usage)) => (Ok(value), usage),
            Err(error) => (Err(error), ObservedUsage::default()),
        };
        let entropy = (self.observe_entropy && matches!(&result, Err(ApiError::Http { .. })))
            .then(RetryEntropy::capture);
        let result = match result {
            Ok(value) => self.publish(value).await,
            Err(error) => Err(error),
        };
        (
            self.id,
            Completion::Attempt(Outcome {
                result,
                usage,
                entropy,
            }),
        )
    }
    fn observe(&self, value: Value) -> Result<(Value, ObservedUsage), ApiError> {
        if matches!(self.expectation, ResponseExpectation::Model)
            && !value
                .get("choices")
                .and_then(Value::as_array)
                .and_then(|choices| choices.first())
                .and_then(|choice| choice.get("message"))
                .is_some_and(Value::is_object)
        {
            return Err(ApiError::Protocol);
        }
        let usage = ObservedUsage::try_from(&value).map_err(|_| ApiError::Protocol)?;
        Ok((value, usage))
    }
    async fn exchange(&self) -> Result<Value, ApiError> {
        let exchange = crate::api::execute_captured(
            self.arguments.as_ref(),
            |value| {
                let sender = self.sender.clone();
                let id = self.id.clone();
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
            self.cancel.clone(),
        );
        if let Some(deadline) = self.deadline {
            tokio::select! {
                biased;
                _ = deadline.elapsed() => Err(ApiError::RunDeadline),
                result = exchange => result,
            }
        } else {
            exchange.await
        }
    }
    async fn publish(&self, value: Value) -> Result<Value, ApiError> {
        let publish = publish_body(&self.sender, &self.id, value, &self.cancel, self.page_bytes);
        if let Some(deadline) = self.deadline {
            tokio::select! {
                biased;
                _ = deadline.elapsed() => Err(ApiError::RunDeadline),
                result = publish => result,
            }
        } else {
            publish.await
        }
    }
}
