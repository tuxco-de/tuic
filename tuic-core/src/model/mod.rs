//! An abstraction of a TUIC connection, with packet fragmentation management
//! and task counters. No I/O operation is involved internally

use std::{
	cell::Cell,
	collections::HashMap,
	fmt::{Debug, Formatter, Result as FmtResult},
	mem,
	sync::{
		Arc,
		atomic::{AtomicU16, Ordering},
	},
	time::{Duration, Instant},
};

use parking_lot::Mutex;
use register_count::{Counter, Register};
use thiserror::Error;
use uuid::Uuid;

use crate::{
	Address, Authenticate as AuthenticateHeader, Connect as ConnectHeader, Dissociate as DissociateHeader,
	Heartbeat as HeartbeatHeader, Packet as PacketHeader,
};

mod authenticate;
mod connect;
mod dissociate;
mod heartbeat;
mod packet;

pub use self::{
	authenticate::{Authenticate, ExportError, KeyingMaterialExporter},
	connect::Connect,
	dissociate::Dissociate,
	heartbeat::Heartbeat,
	packet::{Fragments, Packet},
};

/// An abstraction of a TUIC connection, with packet fragmentation management
/// and task counters. No I/O operation is involved internally
#[derive(Clone)]
pub struct Connection<B> {
	udp_sessions: Arc<Mutex<UdpSessions<B>>>,
	task_connect_count: Counter,
	task_associate_count: Counter,
}

impl<B> Connection<B>
where
	B: AsRef<[u8]>,
{
	/// Creates a new `Connection`
	#[allow(clippy::new_without_default)]
	pub fn new() -> Self {
		let task_associate_count = Counter::new();

		Self {
			udp_sessions: Arc::new(Mutex::new(UdpSessions::new(task_associate_count.clone()))),
			task_connect_count: Counter::new(),
			task_associate_count,
		}
	}

	/// Sends an `Authenticate`
	///
	/// Returns `Err(ExportError)` if TLS keying material export fails.
	pub fn send_authenticate(
		&self,
		uuid: Uuid,
		password: impl AsRef<[u8]>,
		exporter: &impl KeyingMaterialExporter,
	) -> Result<Authenticate<side::Tx>, ExportError> {
		Authenticate::<side::Tx>::new(uuid, password, exporter)
	}

	/// Receives an `Authenticate`
	pub fn recv_authenticate(&self, header: AuthenticateHeader) -> Authenticate<side::Rx> {
		let (uuid, token) = header.into();
		Authenticate::<side::Rx>::new(uuid, token)
	}

	/// Sends a `Connect`
	pub fn send_connect(&self, addr: Address) -> Connect<side::Tx> {
		Connect::<side::Tx>::new(self.task_connect_count.reg(), addr)
	}

	/// Receives a `Connect`
	pub fn recv_connect(&self, header: ConnectHeader) -> Connect<side::Rx> {
		let (addr,) = header.into();
		Connect::<side::Rx>::new(self.task_connect_count.reg(), addr)
	}

	/// Sends a `Packet`
	pub fn send_packet(&self, assoc_id: u16, addr: Address, max_pkt_size: usize) -> Packet<side::Tx, B> {
		self.udp_sessions.lock().send_packet(assoc_id, addr, max_pkt_size)
	}

	/// Receives a `Packet`. If the association ID is not found, returns `None`
	pub fn recv_packet(&self, header: PacketHeader) -> Option<Packet<side::Rx, B>> {
		let (assoc_id, pkt_id, frag_total, frag_id, size, addr) = header.into();
		self.udp_sessions
			.lock()
			.recv_packet(self.udp_sessions.clone(), assoc_id, pkt_id, frag_total, frag_id, size, addr)
	}

	/// Receives a `Packet` without checking the association ID
	pub fn recv_packet_unrestricted(&self, header: PacketHeader) -> Option<Packet<side::Rx, B>> {
		let (assoc_id, pkt_id, frag_total, frag_id, size, addr) = header.into();
		self.udp_sessions.lock().recv_packet_unrestricted(
			self.udp_sessions.clone(),
			assoc_id,
			pkt_id,
			frag_total,
			frag_id,
			size,
			addr,
		)
	}

	/// Sends a `Dissociate`
	pub fn send_dissociate(&self, assoc_id: u16) -> Dissociate<side::Tx> {
		self.udp_sessions.lock().send_dissociate(assoc_id)
	}

	/// Receives a `Dissociate`
	pub fn recv_dissociate(&self, header: DissociateHeader) -> Dissociate<side::Rx> {
		let (assoc_id,) = header.into();
		self.udp_sessions.lock().recv_dissociate(assoc_id)
	}

	/// Sends a `Heartbeat`
	pub fn send_heartbeat(&self) -> Heartbeat<side::Tx> {
		Heartbeat::<side::Tx>::new()
	}

	/// Receives a `Heartbeat`
	pub fn recv_heartbeat(&self, header: HeartbeatHeader) -> Heartbeat<side::Rx> {
		let () = header.into();
		Heartbeat::<side::Rx>::new()
	}

	/// Returns the number of `Connect` tasks
	pub fn task_connect_count(&self) -> usize {
		self.task_connect_count.count()
	}

	/// Returns the number of active UDP sessions
	pub fn task_associate_count(&self) -> usize {
		self.task_associate_count.count()
	}

	/// Removes fragments that can not be reassembled within the specified
	/// timeout
	pub fn collect_garbage(&self, timeout: Duration) {
		self.udp_sessions.lock().collect_garbage(timeout);
	}
}

impl<B> Debug for Connection<B>
where
	B: AsRef<[u8]> + Debug,
{
	fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
		f.debug_struct("Connection")
			.field("udp_sessions", &self.udp_sessions)
			.field("task_connect_count", &self.task_connect_count())
			.field("task_associate_count", &self.task_associate_count())
			.finish()
	}
}

/// Abstracts the side of a task
pub mod side {
	/// The side of a task that sends data
	pub struct Tx;
	/// The side of a task that receives data
	pub struct Rx;

	pub(super) enum Side<T, R> {
		Tx(T),
		Rx(R),
	}
}

struct UdpSessions<B> {
	sessions: HashMap<u16, UdpSession<B>>,
	task_associate_count: Counter,
	pending_fragment_slots: usize,
	pending_fragment_bytes: usize,
}

const MAX_UDP_SESSIONS: usize = 8192;
const MAX_PENDING_PACKETS_PER_SESSION: usize = 256;
const MAX_PENDING_FRAGMENT_SLOTS: usize = 16 * 1024;
const MAX_PENDING_FRAGMENT_BYTES: usize = 16 * 1024 * 1024;

impl<B> UdpSessions<B>
where
	B: AsRef<[u8]>,
{
	fn new(task_associate_count: Counter) -> Self {
		Self {
			sessions: HashMap::new(),
			task_associate_count,
			pending_fragment_slots: 0,
			pending_fragment_bytes: 0,
		}
	}

	fn send_packet(&mut self, assoc_id: u16, addr: Address, max_pkt_size: usize) -> Packet<side::Tx, B> {
		self.sessions
			.entry(assoc_id)
			.or_insert_with(|| UdpSession::new(self.task_associate_count.reg()))
			.send_packet(assoc_id, addr, max_pkt_size)
	}

	#[allow(clippy::too_many_arguments)]
	fn recv_packet(
		&mut self,
		sessions: Arc<Mutex<Self>>,
		assoc_id: u16,
		pkt_id: u16,
		frag_total: u8,
		frag_id: u8,
		size: u16,
		addr: Address,
	) -> Option<Packet<side::Rx, B>> {
		self.sessions
			.get_mut(&assoc_id)
			.map(|session| session.recv_packet(sessions, assoc_id, pkt_id, frag_total, frag_id, size, addr))
	}

	#[allow(clippy::too_many_arguments)]
	fn recv_packet_unrestricted(
		&mut self,
		sessions: Arc<Mutex<Self>>,
		assoc_id: u16,
		pkt_id: u16,
		frag_total: u8,
		frag_id: u8,
		size: u16,
		addr: Address,
	) -> Option<Packet<side::Rx, B>> {
		if !self.sessions.contains_key(&assoc_id) && self.sessions.len() >= MAX_UDP_SESSIONS {
			return None;
		}

		Some(
			self.sessions
				.entry(assoc_id)
				.or_insert_with(|| UdpSession::new(self.task_associate_count.reg()))
				.recv_packet(sessions, assoc_id, pkt_id, frag_total, frag_id, size, addr),
		)
	}

	fn send_dissociate(&mut self, assoc_id: u16) -> Dissociate<side::Tx> {
		self.remove_session(assoc_id);
		Dissociate::<side::Tx>::new(assoc_id)
	}

	fn recv_dissociate(&mut self, assoc_id: u16) -> Dissociate<side::Rx> {
		self.remove_session(assoc_id);
		Dissociate::<side::Rx>::new(assoc_id)
	}

	#[allow(clippy::too_many_arguments)]
	fn insert(
		&mut self,
		assoc_id: u16,
		pkt_id: u16,
		frag_total: u8,
		frag_id: u8,
		size: u16,
		addr: Address,
		data: B,
	) -> Result<Option<Assemblable<B>>, AssembleError> {
		PacketBuffer::<B>::validate_fragment(frag_total, frag_id, &addr)?;

		let data_len = data.as_ref().len();
		let session = self
			.sessions
			.entry(assoc_id)
			.or_insert_with(|| UdpSession::new(self.task_associate_count.reg()));
		let existing = session.pkt_buf.get(&pkt_id);
		let is_new = existing.is_none();
		let existing_bytes = existing.map_or(0, |buf| buf.buffered_bytes);
		let existing_slots = existing.map_or(0, |buf| buf.frag_total as usize);

		if is_new && session.pkt_buf.len() >= MAX_PENDING_PACKETS_PER_SESSION {
			return Err(AssembleError::PendingPacketLimit(MAX_PENDING_PACKETS_PER_SESSION));
		}
		if is_new && self.pending_fragment_slots.saturating_add(frag_total as usize) > MAX_PENDING_FRAGMENT_SLOTS {
			return Err(AssembleError::FragmentSlotLimit(MAX_PENDING_FRAGMENT_SLOTS));
		}
		if self.pending_fragment_bytes.saturating_add(data_len) > MAX_PENDING_FRAGMENT_BYTES {
			return Err(AssembleError::FragmentByteLimit(MAX_PENDING_FRAGMENT_BYTES));
		}

		let result = session.insert(assoc_id, pkt_id, frag_total, frag_id, size, addr, data)?;
		if result.is_some() {
			if !is_new {
				self.pending_fragment_slots = self.pending_fragment_slots.saturating_sub(existing_slots);
				self.pending_fragment_bytes = self.pending_fragment_bytes.saturating_sub(existing_bytes);
			}
		} else {
			if is_new {
				self.pending_fragment_slots += frag_total as usize;
			}
			self.pending_fragment_bytes += data_len;
		}

		Ok(result)
	}

	fn collect_garbage(&mut self, timeout: Duration) {
		for session in self.sessions.values_mut() {
			let (slots, bytes) = session.collect_garbage(timeout);
			self.pending_fragment_slots = self.pending_fragment_slots.saturating_sub(slots);
			self.pending_fragment_bytes = self.pending_fragment_bytes.saturating_sub(bytes);
		}
		// Remove sessions that are empty and have been idle past the timeout.
		// This prevents unbounded accumulation of stale UDP sessions.
		self.sessions.retain(|_, session| !session.is_idle(timeout));
	}

	fn remove_session(&mut self, assoc_id: u16) {
		if let Some(session) = self.sessions.remove(&assoc_id) {
			let (slots, bytes) = session.pending_usage();
			self.pending_fragment_slots = self.pending_fragment_slots.saturating_sub(slots);
			self.pending_fragment_bytes = self.pending_fragment_bytes.saturating_sub(bytes);
		}
	}
}

impl<B> Debug for UdpSessions<B>
where
	B: AsRef<[u8]> + Debug,
{
	fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
		f.debug_struct("UdpSessions").field("sessions", &self.sessions).finish()
	}
}

struct UdpSession<B> {
	pkt_buf: HashMap<u16, PacketBuffer<B>>,
	next_pkt_id: AtomicU16,
	_task_reg: Register,
	last_active: Cell<Instant>,
}

impl<B> UdpSession<B>
where
	B: AsRef<[u8]>,
{
	fn new(task_reg: Register) -> Self {
		Self {
			pkt_buf: HashMap::new(),
			next_pkt_id: AtomicU16::new(0),
			_task_reg: task_reg,
			last_active: Cell::new(Instant::now()),
		}
	}

	fn send_packet(&self, assoc_id: u16, addr: Address, max_pkt_size: usize) -> Packet<side::Tx, B> {
		self.last_active.set(Instant::now());
		Packet::<side::Tx, B>::new(assoc_id, self.next_pkt_id.fetch_add(1, Ordering::AcqRel), addr, max_pkt_size)
	}

	#[allow(clippy::too_many_arguments)]
	fn recv_packet(
		&self,
		sessions: Arc<Mutex<UdpSessions<B>>>,
		assoc_id: u16,
		pkt_id: u16,
		frag_total: u8,
		frag_id: u8,
		size: u16,
		addr: Address,
	) -> Packet<side::Rx, B> {
		Packet::<side::Rx, B>::new(sessions, assoc_id, pkt_id, frag_total, frag_id, size, addr)
	}

	#[allow(clippy::too_many_arguments)]
	fn insert(
		&mut self,
		assoc_id: u16,
		pkt_id: u16,
		frag_total: u8,
		frag_id: u8,
		size: u16,
		addr: Address,
		data: B,
	) -> Result<Option<Assemblable<B>>, AssembleError> {
		let res = self
			.pkt_buf
			.entry(pkt_id)
			.or_insert_with(|| PacketBuffer::new(frag_total))
			.insert(assoc_id, frag_total, frag_id, size, addr, data)?;

		self.last_active.set(Instant::now());

		if res.is_some() {
			self.pkt_buf.remove(&pkt_id);
		}

		Ok(res)
	}

	fn collect_garbage(&mut self, timeout: Duration) -> (usize, usize) {
		let mut removed_slots = 0;
		let mut removed_bytes = 0;
		self.pkt_buf.retain(|_, buf| {
			let keep = buf.c_time.elapsed() < timeout;
			if !keep {
				removed_slots += buf.frag_total as usize;
				removed_bytes += buf.buffered_bytes;
			}
			keep
		});
		(removed_slots, removed_bytes)
	}

	fn pending_usage(&self) -> (usize, usize) {
		self.pkt_buf.values().fold((0, 0), |(slots, bytes), buf| {
			(slots + buf.frag_total as usize, bytes + buf.buffered_bytes)
		})
	}

	fn is_idle(&self, timeout: Duration) -> bool {
		self.pkt_buf.is_empty() && self.last_active.get().elapsed() >= timeout
	}
}

impl<B> Debug for UdpSession<B>
where
	B: AsRef<[u8]> + Debug,
{
	fn fmt(&self, f: &mut Formatter<'_>) -> FmtResult {
		f.debug_struct("UdpSession")
			.field("pkt_buf", &self.pkt_buf)
			.field("next_pkt_id", &self.next_pkt_id)
			.finish()
	}
}

#[derive(Debug)]
struct PacketBuffer<B> {
	buf: Vec<Option<B>>,
	frag_total: u8,
	frag_received: u8,
	addr: Address,
	c_time: Instant,
	buffered_bytes: usize,
}

impl<B> PacketBuffer<B>
where
	B: AsRef<[u8]>,
{
	fn new(frag_total: u8) -> Self {
		let mut buf = Vec::with_capacity(frag_total as usize);
		buf.resize_with(frag_total as usize, || None);

		Self {
			buf,
			frag_total,
			frag_received: 0,
			addr: Address::None,
			c_time: Instant::now(),
			buffered_bytes: 0,
		}
	}

	fn validate_fragment(frag_total: u8, frag_id: u8, addr: &Address) -> Result<(), AssembleError> {
		if frag_id >= frag_total {
			return Err(AssembleError::InvalidFragmentId(frag_total, frag_id));
		}
		if frag_id == 0 && addr.is_none() {
			return Err(AssembleError::InvalidAddress("no address in first fragment"));
		}
		if frag_id != 0 && !addr.is_none() {
			return Err(AssembleError::InvalidAddress("address in non-first fragment"));
		}
		Ok(())
	}

	fn insert(
		&mut self,
		assoc_id: u16,
		frag_total: u8,
		frag_id: u8,
		size: u16,
		addr: Address,
		data: B,
	) -> Result<Option<Assemblable<B>>, AssembleError> {
		assert_eq!(data.as_ref().len(), size as usize);

		Self::validate_fragment(frag_total, frag_id, &addr)?;
		if frag_total != self.frag_total {
			return Err(AssembleError::InconsistentFragmentTotal(self.frag_total, frag_total));
		}

		if self.buf[frag_id as usize].is_some() {
			return Err(AssembleError::DuplicatedFragment(frag_id));
		}

		self.buf[frag_id as usize] = Some(data);
		self.frag_received += 1;
		self.buffered_bytes += size as usize;

		if frag_id == 0 {
			self.addr = addr;
		}

		if self.frag_received == self.frag_total {
			Ok(Some(Assemblable::new(mem::take(&mut self.buf), self.addr.take(), assoc_id)))
		} else {
			Ok(None)
		}
	}
}

/// A complete packet that can be assembled
#[derive(Debug)]
pub struct Assemblable<B> {
	buf: Vec<Option<B>>,
	addr: Address,
	assoc_id: u16,
}

impl<B> Assemblable<B>
where
	B: AsRef<[u8]>,
{
	fn new(buf: Vec<Option<B>>, addr: Address, assoc_id: u16) -> Self {
		Self { buf, addr, assoc_id }
	}

	pub fn assemble<A>(self, buf: &mut A) -> (Address, u16)
	where
		A: Assembler<B>,
	{
		let data = self.buf.into_iter().map(|b| b.unwrap());
		buf.assemble(data);
		(self.addr, self.assoc_id)
	}
}

/// A trait for assembling a packet
pub trait Assembler<B>
where
	Self: Sized,
	B: AsRef<[u8]>,
{
	fn assemble(&mut self, data: impl IntoIterator<Item = B>);
}

impl<B> Assembler<B> for Vec<u8>
where
	B: AsRef<[u8]>,
{
	fn assemble(&mut self, data: impl IntoIterator<Item = B>) {
		for d in data {
			self.extend_from_slice(d.as_ref());
		}
	}
}

/// An error that can occur when assembling a packet
#[derive(Debug, Error)]
pub enum AssembleError {
	#[error("invalid fragment id {1} in total {0} fragments")]
	InvalidFragmentId(u8, u8),
	#[error("{0}")]
	InvalidAddress(&'static str),
	#[error("duplicated fragment: {0}")]
	DuplicatedFragment(u8),
	#[error("inconsistent fragment total: expected {0}, got {1}")]
	InconsistentFragmentTotal(u8, u8),
	#[error("too many pending packets in one UDP session (limit: {0})")]
	PendingPacketLimit(usize),
	#[error("too many pending fragment slots in one connection (limit: {0})")]
	FragmentSlotLimit(usize),
	#[error("too many buffered fragment bytes in one connection (limit: {0})")]
	FragmentByteLimit(usize),
}
