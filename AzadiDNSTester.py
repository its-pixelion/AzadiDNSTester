#!/usr/bin/env python3

"""
Tests DNS servers from dns_servers.txt and saves working ones to working_dns.txt
Supports ANY input format - extracts ALL IPv4 addresses automatically
Requires: pip install dnspython tqdm
"""

import re
import os
import sys
import time
import socket
import threading
import dns.resolver
import dns.exception
from tqdm import tqdm
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

file_lock = threading.Lock()

def get_script_dir():
    """Get directory where script is located"""
    return os.path.dirname(os.path.abspath(__file__))

def create_sample_servers(filename='dns_servers.txt'):
    """Create sample DNS servers file if it doesn't exist"""
    filepath = os.path.join(get_script_dir(), filename)
    if os.path.exists(filepath):
        return
    
    sample_servers = [
        "1.1.1.1",      # Cloudflare
        "1.0.0.1",      # Cloudflare
        "8.8.8.8",      # Google
        "8.8.4.4",      # Google
        "9.9.9.9",      # Quad9
        "208.67.222.222", # OpenDNS
        "208.67.220.220", # OpenDNS
        "4.2.2.1",      # Level3
        "4.2.2.2",      # Level3
    ]
    
    try:
        with open(filepath, 'w') as f:
            for server in sample_servers:
                f.write(f"{server}\n")
        print(f"Created sample {filename} with {len(sample_servers)} servers")
    except Exception as e:
        print(f"Error creating {filename}: {e}")

def load_servers(filename='dns_servers.txt'):
    """Load ALL IPv4 addresses from file - format doesn't matter"""
    filepath = os.path.join(get_script_dir(), filename)
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        
        ip_pattern = re.compile(
            r'\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}'
            r'(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'
        )
        
        all_ips = ip_pattern.findall(content)
        servers = list(set(all_ips))
        
        print(f"Extracted {len(servers)} UNIQUE IPv4 addresses from {filepath}")
        print(f"Total IPs found (with duplicates): {len(all_ips)}")
        print(f"UNIQUE IPs:  {len(servers)}")
        
        if not servers:
            print("No valid IPv4 addresses found. Creating sample file...")
            create_sample_servers(filename)
            return load_servers(filename)
            
        return servers
        
    except FileNotFoundError:
        print(f"{filepath} not found. Creating sample file...")
        create_sample_servers(filename)
        return load_servers(filename)
    except Exception as e:
        print(f"Error loading servers: {e}")
        return []

def write_header(test_domain):
    """Write header to working_dns.txt once before testing"""
    filepath = os.path.join(get_script_dir(), 'working_dns.txt')
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    
    with file_lock:
        try:
            with open(filepath, 'w') as f:
                f.write(f"# Working DNS servers - Tested: {timestamp}\n")
                f.write(f"# Test domain: {test_domain}\n")
                f.write("# Format: IP (response_time_ms)\n")
            print("Header written to working_dns.txt")
        except Exception as e:
            print(f"Header write error: {e}")

def real_time_save(server_info):
    """Thread-safe real-time save of working servers (append only)"""
    filepath = os.path.join(get_script_dir(), 'working_dns.txt')
    
    with file_lock:
        try:
            with open(filepath, 'a') as f:
                f.write(f"{server_info}\n")
        except Exception as e:
            print(f"Real-time save error: {e}")

def get_worker_count():
    """Get worker count from user with validation"""
    while True:
        try:
            print("\nWorkers (parallel tests, default: 100, max: 500):")
            print("  Enter number (1-500) or press Enter for 100")
            choice = input("Workers: ").strip()
            
            if not choice:
                return 100
                
            workers = int(choice)
            if 1 <= workers <= 500:
                return workers
            else:
                print("Invalid! Use 1-500")
        except ValueError:
            print("Invalid! Enter a number")

def get_timeout():
    """Get timeout from user with validation"""
    while True:
        try:
            print("\nTimeout per test (seconds, default: 3, range: 1-10):")
            print("  Enter number (1-10) or press Enter for 3")
            choice = input("Timeout: ").strip()
            
            if not choice:
                return 3
                
            timeout = int(choice)
            if 1 <= timeout <= 10:
                return timeout
            else:
                print("Invalid! Use 1-10 seconds")
        except ValueError:
            print("Invalid! Enter a number")

def get_test_domain():
    """Get valid test domain from user with numbered menu"""
    domains = ["google.com", "cloudflare.com", "example.com"]
    
    print("\nTest domains (enter number 1-3 or type domain):")
    for i, domain in enumerate(domains, 1):
        print(f"  {i}. {domain}")
    print("  or type your own domain")
    
    while True:
        choice = input("\nEnter choice (1-3 or domain): ").strip()
        
        if choice.isdigit() and 1 <= int(choice) <= 3:
            return domains[int(choice) - 1]
        
        if choice and '.' in choice and not choice.startswith(('http://', 'https://')):
            return choice
        
        if not choice:
            return "google.com"
        
        print("Invalid! Use 1-3 or valid domain (e.g., example.com)")

def test_single_server(server, domain, timeout=3):
    """Test single DNS server with response time"""
    try:
        socket.inet_aton(server)
    except socket.error:
        return False, (server, None), f"{server} INVALID IP"
    
    start_time = time.time()
    resolver = dns.resolver.Resolver(configure=False)
    resolver.nameservers = [server]
    resolver.timeout = timeout
    resolver.lifetime = timeout
    
    try:
        answers = resolver.resolve(domain, 'A')
        response_time = (time.time() - start_time) * 1000
        first_ip = str(answers[0])
        result = (server, response_time)
        server_info = f"{server} ({response_time:.0f}ms)"
        
        real_time_save(server_info)
        
        return True, result, f"{server} OK {response_time:.0f}ms ({first_ip}) - {len(answers)} records"
    except dns.resolver.NXDOMAIN:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} NXDOMAIN ({response_time:.0f}ms)"
    except dns.resolver.Timeout:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} TIMEOUT ({timeout}s, {response_time:.0f}ms)"
    except dns.resolver.NoAnswer:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} NO ANSWER ({response_time:.0f}ms)"
    except dns.exception.DNSException as e:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} DNS ERROR ({str(e)[:20]}, {response_time:.0f}ms)"
    except Exception as e:
        response_time = (time.time() - start_time) * 1000
        return False, (server, response_time), f"{server} ERROR ({str(e)[:20]}, {response_time:.0f}ms)"

def check_dns_servers(filename='dns_servers.txt'):
    """Main testing function"""
    print("Azadi DNS Tester")
    print("=" * 70)
    
    servers = load_servers(filename)
    if not servers:
        print("No servers to test. Exiting.")
        return []
    
    workers = get_worker_count()
    timeout = get_timeout()
    domain = get_test_domain()
    
    write_header(domain)
    
    print(f"\nStarting test of {len(servers)} DNS servers")
    print(f"Config: Workers={workers} | Timeout={timeout}s | Domain={domain}")
    print("Working servers will be SAVED IMMEDIATELY as found!")
    print("-" * 70)
    
    start_time = time.time()
    working = []
    failed = []
    
    print("Testing servers...")
    with ThreadPoolExecutor(max_workers=workers) as executor:
        future_to_server = {
            executor.submit(test_single_server, server, domain, timeout): server 
            for server in servers
        }
        
        with tqdm(total=len(servers), desc="Progress", unit="server",
                  bar_format="{l_bar}{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}, {rate_fmt}]") as pbar:
            
            for future in as_completed(future_to_server):
                try:
                    success, result, message = future.result()
                    server_ip, response_time = result
                    
                    if success:
                        working.append(result)
                        tqdm.write(f"✅ {message}")
                    else:
                        failed.append(server_ip)
                        tqdm.write(f"❌ {message}")
                        
                except Exception as e:
                    server = future_to_server[future]
                    failed.append(server)
                    tqdm.write(f"CRASH {server}: {str(e)[:30]}")
                
                pbar.update(1)
    
    print("\n" + "="*60)
    print("DNS SERVER TEST RESULTS")
    print("="*60)

    elapsed = time.time() - start_time
    success_rate = (len(working) / len(servers) * 100) if servers else 0

    print(f"Total servers tested: {len(servers)}")
    print(f"Working servers:      {len(working)} ({success_rate:.1f}%)")
    print(f"Failed servers:       {len(failed)}")
    print(f"Test duration:        {elapsed:.1f} seconds")
    print(f"Test domain:          {domain}")
    print()

    if working:
        print("TOP 5 FASTEST SERVERS:")
        sorted_working = sorted(working, key=lambda x: x[1])
        for i, (server_ip, response_time) in enumerate(sorted_working[:5], 1):
            print(f"  {i}. {server_ip:<15} {response_time:.0f}ms")
        if len(working) > 5:
            print(f"  ... {len(working)-5} more servers")
        print()

    print(f"Results saved: working_dns.txt ({len(working)} servers)")
    print("="*60)
    
    return working

def main():
    """Main entry point"""
    try:
        working_servers = check_dns_servers()
        print("\nTesting complete!")
        input("\nPress Enter to exit...")
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()