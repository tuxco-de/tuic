use std::sync::Arc;

use axum::http::Response;
use bytes::Bytes;
use h3::server;
use tracing::{debug, info};
use tuic_core::quinn::QuinnConnection;

use crate::AppContext;

const STATIC_HTML: &[u8] = b"<!DOCTYPE html><html><head><title>400 Bad Request</title></head><body><center><h1>400 Bad Request</h1></center><hr><center>tuic-server</center></body></html>";

pub async fn handle(
	ctx: Arc<AppContext>,
	conn: QuinnConnection,
	prefetched_uni: Option<crate::h3_quinn_compat::PeekableRecvStream>,
	prefetched_bi: Option<crate::h3_quinn_compat::PrefetchedBiRecv>,
) -> eyre::Result<()> {
	let Some(_camouflage) = ctx.cfg.camouflage.as_ref().filter(|cfg| cfg.enabled) else {
		return Ok(());
	};

	info!(
		id = conn.stable_id() as u32,
		addr = %conn.remote_address(),
		"HTTP/3 camouflage enabled, returning static page for non-protocol traffic"
	);

	let quic_conn = crate::h3_quinn_compat::Connection::new_with_prefetched(conn, prefetched_uni, prefetched_bi);
	let mut h3_conn = server::Connection::new(quic_conn).await?;

	while let Some(resolver) = h3_conn.accept().await? {
		let (request, mut stream) = resolver.resolve_request().await?;
		debug!(
			"[camouflage] incoming h3 request: method={} uri={}",
			request.method(),
			request.uri()
		);

		let resp = Response::builder()
			.status(400)
			.header("content-type", "text/html; charset=utf-8")
			.header("content-length", STATIC_HTML.len().to_string())
			.body(())?;

		_ = stream.send_response(resp).await;
		_ = stream.send_data(Bytes::from_static(STATIC_HTML)).await;
		_ = stream.finish().await;
	}

	Ok(())
}
