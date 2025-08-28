#!/bin/bash

# Generate self-signed certificates for testing HTTP/2 over TLS

echo "Generating self-signed certificates for localhost..."

# Generate private key
openssl genrsa -out localhost.key 4096

# Generate certificate signing request
openssl req -new -key localhost.key -out localhost.csr -subj "/C=US/ST=Test/L=Test/O=Test/CN=localhost"

# Generate self-signed certificate
openssl x509 -req -days 365 -in localhost.csr -signkey localhost.key -out localhost.crt

# Clean up CSR
rm localhost.csr

echo "Certificates generated:"
echo "  - localhost.key (private key)"
echo "  - localhost.crt (certificate)"
echo ""
echo "These are self-signed certificates for testing only."
echo "In production, use proper certificates from a trusted CA."