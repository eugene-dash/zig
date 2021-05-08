// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.

const std = @import("../../std.zig");
const net = @import("net.zig");

const os = std.os;
const mem = std.mem;

const windows = std.os.windows;
const ws2_32 = windows.ws2_32;

pub const Socket = struct {
    /// Import in `Socket.Address` and `Socket.Connection`.
    pub usingnamespace @import("socket.zig").Mixin(Socket);

    /// The underlying handle of a socket.
    fd: os.socket_t,

    /// Open a new socket.
    pub fn init(domain: u32, socket_type: u32, protocol: u32) !Socket {
        var filtered_socket_type = socket_type & ~@as(u32, os.SOCK_CLOEXEC);

        var filtered_flags = ws2_32.WSA_FLAG_OVERLAPPED;
        if (socket_type & os.SOCK_CLOEXEC != 0) {
            filtered_flags |= ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;
        }

        const fd = ws2_32.WSASocketW(
            @intCast(i32, domain),
            @intCast(i32, filtered_socket_type),
            @intCast(i32, protocol),
            null,
            0,
            filtered_flags,
        );
        if (fd == ws2_32.INVALID_SOCKET) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => {
                    _ = try windows.WSAStartup(2, 2);
                    return Socket.init(domain, socket_type, protocol);
                },
                .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                .WSAEMFILE => error.ProcessFdQuotaExceeded,
                .WSAENOBUFS => error.SystemResources,
                .WSAEPROTONOSUPPORT => error.ProtocolNotSupported,
                else => |err| windows.unexpectedWSAError(err),
            };
        }

        return Socket{ .fd = fd };
    }

    /// Enclose a socket abstraction over an existing socket file descriptor.
    pub fn from(fd: os.socket_t) Socket {
        return Socket{ .fd = fd };
    }

    /// Closes the socket.
    pub fn deinit(self: Socket) void {
        _ = ws2_32.closesocket(self.fd);
    }

    /// Shutdown either the read side, write side, or all side of the socket.
    pub fn shutdown(self: Socket, how: os.ShutdownHow) !void {
        const rc = ws2_32.shutdown(self.fd, switch (how) {
            .recv => ws2_32.SD_RECEIVE,
            .send => ws2_32.SD_SEND,
            .both => ws2_32.SD_BOTH,
        });
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAECONNABORTED => return error.ConnectionAborted,
                .WSAECONNRESET => return error.ConnectionResetByPeer,
                .WSAEINPROGRESS => return error.BlockingOperationInProgress,
                .WSAEINVAL => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAENOTCONN => return error.SocketNotConnected,
                .WSAENOTSOCK => unreachable,
                .WSANOTINITIALISED => unreachable,
                else => |err| return windows.unexpectedWSAError(err),
            };
        }
    }

    /// Binds the socket to an address.
    pub fn bind(self: Socket, address: Socket.Address) !void {
        const rc = ws2_32.bind(self.fd, @ptrCast(*const ws2_32.sockaddr, &address.toNative()), @intCast(c_int, address.getNativeSize()));
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSAEACCES => error.AccessDenied,
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                .WSAEFAULT => error.BadAddress,
                .WSAEINPROGRESS => error.WouldBlock,
                .WSAEINVAL => error.AlreadyBound,
                .WSAENOBUFS => error.NoEphemeralPortsAvailable,
                .WSAENOTSOCK => error.NotASocket,
                else => |err| windows.unexpectedWSAError(err),
            };
        }
    }

    /// Start listening for incoming connections on the socket.
    pub fn listen(self: Socket, max_backlog_size: u31) !void {
        const rc = ws2_32.listen(self.fd, max_backlog_size);
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAEISCONN => error.AlreadyConnected,
                .WSAEINVAL => error.SocketNotBound,
                .WSAEMFILE, .WSAENOBUFS => error.SystemResources,
                .WSAENOTSOCK => error.FileDescriptorNotASocket,
                .WSAEOPNOTSUPP => error.OperationNotSupported,
                .WSAEINPROGRESS => error.WouldBlock,
                else => |err| windows.unexpectedWSAError(err),
            };
        }
    }

    /// Have the socket attempt to the connect to an address.
    pub fn connect(self: Socket, address: Socket.Address) !void {
        const rc = ws2_32.connect(self.fd, @ptrCast(*const ws2_32.sockaddr, &address.toNative()), @intCast(c_int, address.getNativeSize()));
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                .WSAECONNREFUSED => error.ConnectionRefused,
                .WSAETIMEDOUT => error.ConnectionTimedOut,
                .WSAEFAULT => error.BadAddress,
                .WSAEINVAL => error.ListeningSocket,
                .WSAEISCONN => error.AlreadyConnected,
                .WSAENOTSOCK => error.NotASocket,
                .WSAEACCES => error.BroadcastNotEnabled,
                .WSAENOBUFS => error.SystemResources,
                .WSAEAFNOSUPPORT => error.AddressFamilyNotSupported,
                .WSAEINPROGRESS, .WSAEWOULDBLOCK => error.WouldBlock,
                .WSAEHOSTUNREACH, .WSAENETUNREACH => error.NetworkUnreachable,
                else => |err| windows.unexpectedWSAError(err),
            };
        }
    }

    /// Accept a pending incoming connection queued to the kernel backlog
    /// of the socket.
    pub fn accept(self: Socket, flags: u32) !Socket.Connection {
        var address: ws2_32.sockaddr_storage = undefined;
        var address_len: c_int = @sizeOf(ws2_32.sockaddr_storage);

        const rc = ws2_32.accept(self.fd, @ptrCast(*ws2_32.sockaddr, &address), &address_len);
        if (rc == ws2_32.INVALID_SOCKET) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAECONNRESET => error.ConnectionResetByPeer,
                .WSAEFAULT => unreachable,
                .WSAEINVAL => error.SocketNotListening,
                .WSAEMFILE => error.ProcessFdQuotaExceeded,
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSAENOBUFS => error.FileDescriptorNotASocket,
                .WSAEOPNOTSUPP => error.OperationNotSupported,
                .WSAEWOULDBLOCK => error.WouldBlock,
                else => |err| windows.unexpectedWSAError(err),
            };
        }

        const socket = Socket.from(rc);
        const socket_address = Socket.Address.fromNative(@alignCast(4, @ptrCast(*ws2_32.sockaddr, &address)));

        return Socket.Connection.from(socket, socket_address);
    }

    /// Read data from the socket into the buffer provided with a set of flags
    /// specified. It returns the number of bytes read into the buffer provided.
    pub fn read(self: Socket, buf: []u8, flags: u32) !usize {
        var bufs = &[_]ws2_32.WSABUF{.{ .len = @intCast(u32, buf.len), .buf = buf.ptr }};
        var flags_ = flags;

        const rc = ws2_32.WSARecv(self.fd, bufs, 1, null, &flags_, null, null);
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAECONNABORTED => error.ConnectionAborted,
                .WSAECONNRESET => error.ConnectionResetByPeer,
                .WSAEDISCON => error.ConnectionClosedByPeer,
                .WSAEFAULT => error.BadBuffer,
                .WSAEINPROGRESS,
                .WSAEWOULDBLOCK,
                .WSA_IO_PENDING,
                .WSAETIMEDOUT,
                => error.WouldBlock,
                .WSAEINTR => error.Cancelled,
                .WSAEINVAL => error.SocketNotBound,
                .WSAEMSGSIZE => error.MessageTooLarge,
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSAENETRESET => error.NetworkReset,
                .WSAENOTCONN => error.SocketNotConnected,
                .WSAENOTSOCK => error.FileDescriptorNotASocket,
                .WSAEOPNOTSUPP => error.OperationNotSupported,
                .WSAESHUTDOWN => error.AlreadyShutdown,
                .WSA_OPERATION_ABORTED => error.OperationAborted,
                else => |err| windows.unexpectedWSAError(err),
            };
        }

        return @intCast(usize, rc);
    }

    /// Write a buffer of data provided to the socket with a set of flags specified.
    /// It returns the number of bytes that are written to the socket.
    pub fn write(self: Socket, buf: []const u8, flags: u32) !usize {
        var bufs = &[_]ws2_32.WSABUF{.{ .len = @intCast(u32, buf.len), .buf = buf.ptr }};
        var flags_ = flags;

        const rc = ws2_32.WSASend(self.fd, bufs, 1, null, &flags_, null, null);
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAECONNABORTED => error.ConnectionAborted,
                .WSAECONNRESET => error.ConnectionResetByPeer,
                .WSAEFAULT => error.BadBuffer,
                .WSAEINPROGRESS,
                .WSAEWOULDBLOCK,
                .WSA_IO_PENDING,
                .WSAETIMEDOUT,
                => error.WouldBlock,
                .WSAEINTR => error.Cancelled,
                .WSAEINVAL => error.SocketNotBound,
                .WSAEMSGSIZE => error.MessageTooLarge,
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSAENETRESET => error.NetworkReset,
                .WSAENOBUFS => error.BufferDeadlock,
                .WSAENOTCONN => error.SocketNotConnected,
                .WSAENOTSOCK => error.FileDescriptorNotASocket,
                .WSAEOPNOTSUPP => error.OperationNotSupported,
                .WSAESHUTDOWN => error.AlreadyShutdown,
                .WSA_OPERATION_ABORTED => error.OperationAborted,
                else => |err| windows.unexpectedWSAError(err),
            };
        }

        return @intCast(usize, rc);
    }

    /// Writes multiple I/O vectors with a prepended message header to the socket
    /// with a set of flags specified. It returns the number of bytes that are
    /// written to the socket.
    pub fn writeVectorized(self: Socket, msg: os.msghdr_const, flags: u32) !usize {
        return error.NotImplemented;
    }

    /// Read multiple I/O vectors with a prepended message header from the socket
    /// with a set of flags specified. It returns the number of bytes that were
    /// read into the buffer provided.
    pub fn readVectorized(self: Socket, msg: *os.msghdr, flags: u32) !usize {
        return error.NotImplemented;
    }

    /// Query the address that the socket is locally bounded to.
    pub fn getLocalAddress(self: Socket) !Socket.Address {
        var address: ws2_32.sockaddr_storage = undefined;
        var address_len: c_int = @sizeOf(ws2_32.sockaddr_storage);

        const rc = ws2_32.getsockname(self.fd, @ptrCast(*ws2_32.sockaddr, &address), &address_len);
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAEFAULT => unreachable,
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSAENOTSOCK => error.FileDescriptorNotASocket,
                .WSAEINVAL => error.SocketNotBound,
                else => |err| windows.unexpectedWSAError(err),
            };
        }

        return Socket.Address.fromNative(@alignCast(4, @ptrCast(*os.sockaddr, &address)));
    }

    /// Query the address that the socket is connected to.
    pub fn getRemoteAddress(self: Socket) !Socket.Address {
        var address: ws2_32.sockaddr_storage = undefined;
        var address_len: c_int = @sizeOf(ws2_32.sockaddr_storage);

        const rc = ws2_32.getpeername(self.fd, @ptrCast(*ws2_32.sockaddr, &address), &address_len);
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAEFAULT => unreachable,
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSAENOTSOCK => error.FileDescriptorNotASocket,
                .WSAEINVAL => error.SocketNotBound,
                else => |err| windows.unexpectedWSAError(err),
            };
        }

        return Socket.Address.fromNative(@alignCast(4, @ptrCast(*os.sockaddr, &address)));
    }

    /// Query and return the latest cached error on the socket.
    pub fn getError(self: Socket) !void {
        return {};
    }

    /// Query the read buffer size of the socket.
    pub fn getReadBufferSize(self: Socket) !u32 {
        return 0;
    }

    /// Query the write buffer size of the socket.
    pub fn getWriteBufferSize(self: Socket) !u32 {
        return 0;
    }

    /// Set a socket option.
    pub fn setOption(self: Socket, level: u32, name: u32, value: []const u8) !void {
        const rc = ws2_32.setsockopt(self.fd, @intCast(i32, level), @intCast(i32, name), value.ptr, @intCast(i32, value.len));
        if (rc == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAEFAULT => unreachable,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEINVAL => return error.SocketNotBound,
                .WSAENOTCONN => return error.SocketNotConnected,
                .WSAESHUTDOWN => return error.AlreadyShutdown,
                else => |err| windows.unexpectedWSAError(err),
            };
        }
    }

    /// Have close() or shutdown() syscalls block until all queued messages in the socket have been successfully
    /// sent, or if the timeout specified in seconds has been reached. It returns `error.UnsupportedSocketOption`
    /// if the host does not support the option for a socket to linger around up until a timeout specified in
    /// seconds.
    pub fn setLinger(self: Socket, timeout_seconds: ?u16) !void {
        const settings = ws2_32.linger{
            .l_onoff = @as(u16, @boolToInt(timeout_seconds != null)),
            .l_linger = if (timeout_seconds) |seconds| seconds else 0,
        };

        return self.setOption(ws2_32.SOL_SOCKET, ws2_32.SO_LINGER, mem.asBytes(&settings));
    }

    /// On connection-oriented sockets, have keep-alive messages be sent periodically. The timing in which keep-alive
    /// messages are sent are dependant on operating system settings. It returns `error.UnsupportedSocketOption` if
    /// the host does not support periodically sending keep-alive messages on connection-oriented sockets. 
    pub fn setKeepAlive(self: Socket, enabled: bool) !void {
        return self.setOption(ws2_32.SOL_SOCKET, ws2_32.SO_KEEPALIVE, mem.asBytes(&@as(u32, @boolToInt(enabled))));
    }

    /// Allow multiple sockets on the same host to listen on the same address. It returns `error.UnsupportedSocketOption` if
    /// the host does not support sockets listening the same address.
    pub fn setReuseAddress(self: Socket, enabled: bool) !void {
        return self.setOption(ws2_32.SOL_SOCKET, ws2_32.SO_REUSEADDR, mem.asBytes(&@as(u32, @boolToInt(enabled))));
    }

    /// Allow multiple sockets on the same host to listen on the same port. It returns `error.UnsupportedSocketOption` if
    /// the host does not supports sockets listening on the same port.
    ///
    /// TODO: verify if this truly mimicks SO_REUSEPORT behavior, or if SO_REUSE_UNICASTPORT provides the correct behavior
    pub fn setReusePort(self: Socket, enabled: bool) !void {
        try self.setOption(ws2_32.SOL_SOCKET, ws2_32.SO_BROADCAST, mem.asBytes(&@as(u32, @boolToInt(enabled))));
        try self.setReuseAddress(enabled);
    }

    /// Set the write buffer size of the socket.
    pub fn setWriteBufferSize(self: Socket, size: u32) !void {
        return self.setOption(ws2_32.SOL_SOCKET, ws2_32.SO_SNDBUF, mem.asBytes(&size));
    }

    /// Set the read buffer size of the socket.
    pub fn setReadBufferSize(self: Socket, size: u32) !void {
        return self.setOption(ws2_32.SOL_SOCKET, ws2_32.SO_RCVBUF, mem.asBytes(&size));
    }

    /// Set a timeout on the socket that is to occur if no messages are successfully written
    /// to its bound destination after a specified number of milliseconds. A subsequent write
    /// to the socket will thereafter return `error.WouldBlock` should the timeout be exceeded.
    pub fn setWriteTimeout(self: Socket, milliseconds: u32) !void {
        return self.setOption(ws2_32.SOL_SOCKET, ws2_32.SO_SNDTIMEO, mem.asBytes(&milliseconds));
    }

    /// Set a timeout on the socket that is to occur if no messages are successfully read
    /// from its bound destination after a specified number of milliseconds. A subsequent
    /// read from the socket will thereafter return `error.WouldBlock` should the timeout be
    /// exceeded.
    pub fn setReadTimeout(self: Socket, milliseconds: u32) !void {
        return self.setOption(ws2_32.SOL_SOCKET, ws2_32.SO_RCVTIMEO, mem.asBytes(&milliseconds));
    }
};
