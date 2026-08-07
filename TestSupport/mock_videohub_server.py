#!/usr/bin/env python3
"""Small development-only Smart Videohub TCP server.

It deliberately fragments its initial status dump across awkward packet sizes,
pushes one external route update, and acknowledges route/PING commands. This is
not a protocol simulator; it only exercises the v1 app paths.
"""

from __future__ import annotations

import argparse
import signal
import socket
import threading
import time
from dataclasses import dataclass, field


@dataclass
class RouterState:
    size: int
    routes: dict[int, int] = field(init=False)
    send_lock: threading.Lock = field(default_factory=threading.Lock)

    def __post_init__(self) -> None:
        self.routes = {output: output % self.size for output in range(self.size)}

    def input_label(self, index: int) -> str:
        return f"Input {index + 1}"

    def output_label(self, index: int) -> str:
        return f"Output {index + 1}"

    def dump(self) -> str:
        blocks = [
            "PROTOCOL PREAMBLE:\nVersion: 2.3\nFuture version field: ignored\n\n",
            (
                "VIDEOHUB DEVICE:\n"
                "Device present: true\n"
                "Model name: MOCK-VH-ONSET\n"
                f"Video inputs: {self.size}\n"
                "Video processing units: 0\n"
                f"Video outputs: {self.size}\n"
                "Video monitoring outputs: 0\n"
                "Serial ports: 0\n"
                "Future device field: ignored\n\n"
            ),
            "INPUT LABELS:\n"
            + "".join(f"{index} {self.input_label(index)}\n" for index in range(self.size))
            + "\n",
            "OUTPUT LABELS:\n"
            + "".join(f"{index} {self.output_label(index)}\n" for index in range(self.size))
            + "\n",
            "VIDEO OUTPUT ROUTING:\n"
            + "".join(f"{output} {source}\n" for output, source in self.routes.items())
            + "\n",
            "VIDEO OUTPUT LOCKS:\n"
            + "".join(
                f"{output} {'L' if output == min(5, self.size - 1) else 'U'}\n"
                for output in range(self.size)
            )
            + "\n",
            "FUTURE ROUTER BLOCK:\n0 Ignored safely\n\n",
        ]
        return "".join(blocks)


class MockVideohubServer:
    def __init__(self, host: str, port: int, size: int, reject_routes: bool) -> None:
        self.host = host
        self.port = port
        self.state = RouterState(size=size)
        self.reject_routes = reject_routes
        self.running = True
        self.server: socket.socket | None = None

    def stop(self, *_: object) -> None:
        self.running = False
        if self.server is not None:
            try:
                self.server.close()
            except OSError:
                pass

    def serve(self) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            self.server = server
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind((self.host, self.port))
            # Port zero lets automated tests ask the kernel for a free port,
            # avoiding collisions with local Videohub tools or parallel jobs.
            self.port = int(server.getsockname()[1])
            server.listen(4)
            server.settimeout(0.5)
            print(f"READY {self.host}:{self.port} size={self.state.size}", flush=True)

            while self.running:
                try:
                    connection, address = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break

                print(f"CONNECTED {address[0]}:{address[1]}", flush=True)
                with connection:
                    connection.settimeout(0.5)
                    self.send_fragmented(connection, self.state.dump().encode("utf-8"))
                    external = threading.Thread(
                        target=self.push_external_update,
                        args=(connection,),
                        daemon=True,
                    )
                    external.start()
                    self.handle_client(connection)
                print("DISCONNECTED", flush=True)

    def send_fragmented(self, connection: socket.socket, payload: bytes) -> None:
        pattern = (1, 2, 7, 3, 19, 5, 31)
        offset = 0
        pattern_index = 0
        with self.state.send_lock:
            while offset < len(payload):
                length = pattern[pattern_index % len(pattern)]
                connection.sendall(payload[offset : offset + length])
                offset += length
                pattern_index += 1

    def send_text(self, connection: socket.socket, text: str) -> None:
        with self.state.send_lock:
            connection.sendall(text.encode("utf-8"))

    def push_external_update(self, connection: socket.socket) -> None:
        time.sleep(0.8)
        if not self.running:
            return
        output = 0
        source = min(2, self.state.size - 1)
        self.state.routes[output] = source
        try:
            self.send_text(connection, f"VIDEO OUTPUT ROUTING:\n{output} {source}\n\n")
            print(f"EXTERNAL_ROUTE {output} {source}", flush=True)
        except OSError:
            pass

    def handle_client(self, connection: socket.socket) -> None:
        buffer = bytearray()
        while self.running:
            try:
                chunk = connection.recv(65_536)
            except socket.timeout:
                continue
            except OSError:
                return
            if not chunk:
                return
            buffer.extend(chunk.replace(b"\r\n", b"\n"))

            while b"\n\n" in buffer:
                raw_block, _, remainder = buffer.partition(b"\n\n")
                buffer = bytearray(remainder)
                self.handle_block(connection, raw_block.decode("utf-8", errors="replace"))

    def handle_block(self, connection: socket.socket, block: str) -> None:
        lines = block.splitlines()
        if not lines:
            return
        if lines[0] == "PING:":
            self.send_text(connection, "ACK\n\n")
            print("PING", flush=True)
            return

        if lines[0] == "VIDEO OUTPUT ROUTING:" and len(lines) >= 2:
            try:
                output, source = (int(value) for value in lines[1].split(maxsplit=1))
            except (ValueError, TypeError):
                self.send_text(connection, "NAK\n\n")
                print("NAK malformed route", flush=True)
                return
            if output not in self.state.routes or not 0 <= source < self.state.size:
                self.send_text(connection, "NAK\n\n")
                print(f"NAK route {output} {source}", flush=True)
                return

            if self.reject_routes:
                self.send_text(connection, "NAK\n\n")
                print(f"NAK route {output} {source}", flush=True)
                return

            print(f"ROUTE_COMMAND {output} {source}", flush=True)
            self.send_text(connection, "ACK\n\n")
            time.sleep(0.15)
            self.state.routes[output] = source
            self.send_text(connection, f"VIDEO OUTPUT ROUTING:\n{output} {source}\n\n")
            print(f"ROUTE_STATUS {output} {source}", flush=True)
            return

        self.send_text(connection, "NAK\n\n")
        print(f"NAK unknown command {lines[0]}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9990)
    parser.add_argument("--size", type=int, default=8)
    parser.add_argument("--reject-routes", action="store_true")
    arguments = parser.parse_args()

    server = MockVideohubServer(
        arguments.host,
        arguments.port,
        max(1, arguments.size),
        arguments.reject_routes,
    )
    signal.signal(signal.SIGTERM, server.stop)
    signal.signal(signal.SIGINT, server.stop)
    server.serve()


if __name__ == "__main__":
    main()
