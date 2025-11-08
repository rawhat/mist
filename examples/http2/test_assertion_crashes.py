#!/usr/bin/env python3
"""
Python script to generate specific HTTP/2 scenarios that target dangerous assertions
This creates more precise attack vectors than shell scripts can generate
"""

import socket
import time
import threading
import sys

def test_malformed_utf8_headers():
    """Test malformed UTF-8 in headers to trigger bit_array.to_string assertions"""
    print("🎯 Test: Malformed UTF-8 Headers")
    
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(('localhost', 9080))
        
        # Send HTTP request with invalid UTF-8 in header
        request = b"GET / HTTP/1.1\r\n"
        request += b"Host: localhost:9080\r\n"
        # Invalid UTF-8: start of 2-byte sequence without continuation
        request += b"X-Bad-Header: \xC0test\r\n"
        request += b"\r\n"
        
        s.send(request)
        
        # Try to read response (may not get one if server crashes)
        s.settimeout(2)
        try:
            response = s.recv(1024)
            print(f"   Server responded: {len(response)} bytes")
        except socket.timeout:
            print("   No response (server may have crashed)")
        
        s.close()
        
    except Exception as e:
        print(f"   Exception: {e}")

def test_stream_assertion():
    """Test to trigger the stream assertion by creating specific race condition"""
    print("🎯 Test: Stream State Assertion")
    
    def create_rapid_stream():
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.connect(('localhost', 9080))
            
            # Send HTTP/2 preface
            preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
            s.send(preface)
            
            # Send SETTINGS frame (empty)
            # Frame: length=0, type=4 (SETTINGS), flags=0, stream=0
            settings = b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
            s.send(settings)
            
            # Send HEADERS frame for stream 1 with END_STREAM flag
            # This might trigger the assertion when combined with rapid closure
            headers = b"\x00\x00\x10\x01\x05\x00\x00\x00\x01"  # Basic HEADERS frame
            headers += b"\x00\x00\x82\x86\x84\x41\x0f\x77\x77\x77\x2e\x65\x78\x61\x6d\x70\x6c\x65\x2e\x63\x6f\x6d"
            s.send(headers)
            
            # Immediately close to create race condition
            s.close()
            
        except Exception as e:
            pass  # Expected to fail
    
    # Create multiple rapid connections
    threads = []
    for i in range(3):
        t = threading.Thread(target=create_rapid_stream)
        threads.append(t)
        t.start()
        time.sleep(0.01)  # Small delay
    
    for t in threads:
        t.join(timeout=1)

def test_websocket_assertion():
    """Test WebSocket upgrade to trigger process assertion"""
    print("🎯 Test: WebSocket Process Assertion")
    
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(('localhost', 9080))
        
        # Send WebSocket upgrade request
        request = b"GET /ws HTTP/1.1\r\n"
        request += b"Host: localhost:9080\r\n"
        request += b"Upgrade: websocket\r\n"
        request += b"Connection: Upgrade\r\n"
        request += b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
        request += b"Sec-WebSocket-Version: 13\r\n"
        request += b"\r\n"
        
        s.send(request)
        
        # Close immediately to potentially trigger process assertion
        s.close()
        
    except Exception as e:
        print(f"   WebSocket test exception: {e}")

def test_hpack_decode_assertion():
    """Test HPACK decoding that might trigger the decode assertion we fixed"""
    print("🎯 Test: HPACK Decode Edge Case")
    
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(('localhost', 9080))
        
        # Send HTTP/2 preface
        preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        s.send(preface)
        
        # Wait a bit for server to process
        time.sleep(0.1)
        
        # Send malformed HEADERS frame with bad HPACK data
        # Frame: length=5, type=1 (HEADERS), flags=4 (END_HEADERS), stream=1
        bad_hpack = b"\x00\x00\x05\x01\x04\x00\x00\x00\x01"
        bad_hpack += b"\xFF\xFF\xFF\xFF\xFF"  # Invalid HPACK data
        
        s.send(bad_hpack)
        
        # Try to read response
        s.settimeout(2)
        try:
            response = s.recv(1024)
            print(f"   HPACK test: got {len(response)} bytes")
        except socket.timeout:
            print("   HPACK test: timeout (potential crash)")
        
        s.close()
        
    except Exception as e:
        print(f"   HPACK test exception: {e}")

def test_frame_size_assertion():
    """Test frame size edge cases that might trigger panics"""
    print("🎯 Test: Frame Size Edge Cases")
    
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.connect(('localhost', 9080))
        
        # Send HTTP/2 preface
        preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        s.send(preface)
        
        time.sleep(0.1)
        
        # Send frame with maximum size (should be rejected)
        # Frame: length=0xFFFFFF (16MB), type=1 (HEADERS), flags=0, stream=1
        huge_frame = b"\xFF\xFF\xFF\x01\x00\x00\x00\x00\x01"
        s.send(huge_frame)
        
        # The server should reject this, but let's see what happens
        s.settimeout(2)
        try:
            response = s.recv(1024)
            print(f"   Frame size test: got {len(response)} bytes")
        except socket.timeout:
            print("   Frame size test: timeout")
        
        s.close()
        
    except Exception as e:
        print(f"   Frame size test exception: {e}")

def check_server_alive():
    """Check if server is still responding"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2)
        s.connect(('localhost', 9080))
        
        request = b"GET / HTTP/1.1\r\nHost: localhost:9080\r\n\r\n"
        s.send(request)
        
        response = s.recv(1024)
        s.close()
        
        return len(response) > 0
        
    except:
        return False

def main():
    print("=" * 50)
    print("HTTP/2 Assertion Crash Test Suite")
    print("=" * 50)
    print()
    
    print("⚠️  These tests target specific assertions that may crash the server")
    print("⚠️  Monitor server output for crashes and supervisor reports")
    print()
    
    if not check_server_alive():
        print("❌ Server not responding on localhost:9080")
        sys.exit(1)
    
    print("✅ Server is alive, starting tests...")
    print()
    
    # Run each test
    test_malformed_utf8_headers()
    time.sleep(0.5)
    
    test_stream_assertion()
    time.sleep(0.5)
    
    test_websocket_assertion()
    time.sleep(0.5)
    
    test_hpack_decode_assertion()
    time.sleep(0.5)
    
    test_frame_size_assertion()
    time.sleep(1)
    
    # Check if server survived
    print()
    if check_server_alive():
        print("✅ Server survived all tests")
    else:
        print("💥 Server appears to have crashed!")
    
    print()
    print("📋 Check server logs for:")
    print("   - Assertion failures")
    print("   - Supervisor crash reports")
    print("   - Pattern match failures")
    print("   - Process terminations")

if __name__ == "__main__":
    main()