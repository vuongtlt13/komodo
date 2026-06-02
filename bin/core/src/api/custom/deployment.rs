use anyhow::anyhow;
use axum::{Extension, Router, routing::post};
use komodo_client::{
  api::execute::DeployStack,
  entities::{
    repo::{_PartialRepoConfig, Repo},
    stack::{_PartialStackConfig, Stack},
    update::Update,
    user::User,
  },
};
use mogh_error::{Json, Result};
use serde::{Deserialize, Serialize};

use crate::{
  api::execute::{self, ExecuteRequest, ExecutionResult},
  resource,
};

pub fn router() -> Router {
  Router::new()
    .route("/recreate-repo", post(recreate_repo))
    .route("/upsert-stack-from-repo", post(upsert_stack_from_repo))
    .route("/deploy-stack", post(deploy_stack))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RecreateRepoRequest {
  /// The fixed Repo name used by CI/CD.
  name: String,
  /// Optional partial Repo config to create/update with.
  #[serde(default)]
  config: _PartialRepoConfig,
  /// If true, delete any existing Repo with the same name before creating it again.
  #[serde(default)]
  recreate: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum RecreateRepoAction {
  Created,
  Updated,
  Recreated,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RecreateRepoResponse {
  action: RecreateRepoAction,
  repo: Repo,
}

async fn recreate_repo(
  Extension(user): Extension<User>,
  Json(request): Json<RecreateRepoRequest>,
) -> Result<Json<RecreateRepoResponse>> {
  let existing = resource::get::<Repo>(&request.name).await.ok();

  let (action, repo) = match (existing, request.recreate) {
    (Some(existing), true) => {
      resource::delete::<Repo>(&existing.id, &user).await?;
      let repo = resource::create::<Repo>(
        &request.name,
        request.config,
        None,
        &user,
      )
      .await?;
      (RecreateRepoAction::Recreated, repo)
    }
    (Some(existing), false) => {
      let repo =
        resource::update::<Repo>(&existing.id, request.config, &user)
          .await?;
      (RecreateRepoAction::Updated, repo)
    }
    (None, _) => {
      let repo = resource::create::<Repo>(
        &request.name,
        request.config,
        None,
        &user,
      )
      .await?;
      (RecreateRepoAction::Created, repo)
    }
  };

  Ok(Json(RecreateRepoResponse { action, repo }))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UpsertStackFromRepoRequest {
  /// The Repo name or id to link to the Stack.
  repo: String,
  /// The fixed Stack name used by CI/CD.
  name: String,
  /// Optional partial Stack config to create/update with.
  #[serde(default)]
  config: _PartialStackConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum UpsertStackFromRepoAction {
  Created,
  Updated,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UpsertStackFromRepoResponse {
  action: UpsertStackFromRepoAction,
  repo: Repo,
  stack: Stack,
}

async fn upsert_stack_from_repo(
  Extension(user): Extension<User>,
  Json(mut request): Json<UpsertStackFromRepoRequest>,
) -> Result<Json<UpsertStackFromRepoResponse>> {
  let repo = resource::get::<Repo>(&request.repo).await?;
  request.config.linked_repo = Some(repo.id.clone());

  let existing = resource::get::<Stack>(&request.name).await.ok();

  let (action, stack) = if let Some(existing) = existing {
    let stack =
      resource::update::<Stack>(&existing.id, request.config, &user)
        .await?;
    (UpsertStackFromRepoAction::Updated, stack)
  } else {
    let stack = resource::create::<Stack>(
      &request.name,
      request.config,
      None,
      &user,
    )
    .await?;
    (UpsertStackFromRepoAction::Created, stack)
  };

  Ok(Json(UpsertStackFromRepoResponse {
    action,
    repo,
    stack,
  }))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DeployStackRequest {
  /// Stack id or name.
  stack: String,
  /// Filter to only deploy specific services. If empty, deploy all services.
  #[serde(default)]
  services: Vec<String>,
  /// Override the default termination max time.
  stop_time: Option<i32>,
}

async fn deploy_stack(
  Extension(user): Extension<User>,
  Json(request): Json<DeployStackRequest>,
) -> Result<Json<Update>> {
  let result = execute::inner_handler(
    ExecuteRequest::DeployStack(DeployStack {
      stack: request.stack,
      services: request.services,
      stop_time: request.stop_time,
    }),
    user,
  )
  .await?;

  match result {
    ExecutionResult::Single(update) => Ok(Json(*update)),
    ExecutionResult::Batch(_) => Err(
      anyhow!("Deploy stack returned unexpected batch result").into(),
    ),
  }
}
