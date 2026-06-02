use axum::{Router, middleware};
use mogh_auth_server::middleware::authenticate_request;

use crate::auth::KomodoAuthImpl;

mod deployment;

pub fn router() -> Router {
  Router::new()
    .nest("/deployment", deployment::router())
    .layer(middleware::from_fn(
      authenticate_request::<KomodoAuthImpl, true>,
    ))
}
