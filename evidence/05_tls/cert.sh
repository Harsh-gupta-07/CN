export PATH="/opt/homebrew/opt/openssl/bin:$PATH"
mkdir -p ~/jio-ca && cd ~/jio-ca
openssl genrsa -out ca.key 4096
openssl req -x509 -new -key ca.key -sha256 -days 365 -subj "/CN=Jio Local CA" \
  -addext "basicConstraints=critical,CA:TRUE" -out ca.crt
openssl genrsa -out app.key 2048
openssl req -new -key app.key -subj "/CN=app.jio.test" -out app.csr
cat > san.ext <<EOF
subjectAltName=DNS:app.jio.test,DNS:api.jio.test
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in app.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out app.crt -days 90 -sha256 -extfile san.ext
openssl x509 -in app.crt -noout -text | grep -A1 "Alternative"   # SAN must list both names
sudo mkdir -p /opt/homebrew/etc/nginx/certs
sudo cp app.crt app.key /opt/homebrew/etc/nginx/certs/