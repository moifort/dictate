# Minimal App Store Connect API client.
#
#   ruby scripts/app-store/asc.rb GET /v1/apps
#
# Reads the key from ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH, as the
# release workflow and scripts/build-app-store.sh do.
require "openssl"
require "json"
require "net/http"
require "base64"

module ASC
  module_function

  def token
    key_id = ENV.fetch("ASC_KEY_ID")
    path = ENV.fetch("ASC_KEY_PATH", "~/.appstoreconnect/private_keys/AuthKey_#{key_id}.p8")
    key = OpenSSL::PKey::EC.new(File.read(File.expand_path(path)))
    b64 = ->(s) { Base64.urlsafe_encode64(s, padding: false) }
    now = Time.now.to_i
    signing = [
      b64.(JSON.dump(alg: "ES256", kid: key_id, typ: "JWT")),
      b64.(JSON.dump(iss: ENV.fetch("ASC_ISSUER_ID"), iat: now, exp: now + 1100, aud: "appstoreconnect-v1"))
    ].join(".")
    # ES256 wants the raw r||s pair, OpenSSL signs in DER.
    der = OpenSSL::ASN1.decode(key.sign(OpenSSL::Digest::SHA256.new, signing))
    signature = der.value.map { |i| i.value.to_s(2).rjust(32, "\x00")[-32..] }.join
    "#{signing}.#{b64.(signature)}"
  end

  # Returns [status, parsed body]. Raises on 4xx/5xx unless `allow` lists the status.
  def request(method, path, body = nil, allow = [])
    uri = URI(path.start_with?("http") ? path : "https://api.appstoreconnect.apple.com#{path}")
    req = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Content-Type"] = "application/json"
    req.body = body.is_a?(String) ? body : JSON.dump(body) if body
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    parsed = res.body.to_s.empty? ? {} : JSON.parse(res.body)
    status = res.code.to_i
    if status >= 400 && !allow.include?(status)
      raise "#{method} #{path}: HTTP #{status}\n#{JSON.pretty_generate(parsed)[0, 1500]}"
    end
    [status, parsed]
  end

  def get(path)
    request(:get, path)[1]
  end
end

if $PROGRAM_NAME == __FILE__
  method, path, body = ARGV
  status, parsed = ASC.request(method, path, body, (400..599).to_a)
  warn "HTTP #{status}"
  puts JSON.pretty_generate(parsed)
end
