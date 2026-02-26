# frozen_string_literal: true

##
# Ruby Transcription Starter - Backend Server
#
# Minimal Sinatra server providing prerecorded audio transcription
# powered by Deepgram's speech-to-text service.
#
# Key Features:
# - Contract-compliant API endpoint: POST /api/transcription
# - Accepts audio file upload (multipart form data)
# - Supports multiple transcription options via query parameters
# - JWT session auth with rate limiting (production only)
# - CORS enabled for frontend communication

require 'sinatra'
require 'sinatra/cross_origin'
require 'json'
require 'jwt'
require 'securerandom'
require 'net/http'
require 'uri'
require 'toml-rb'
require 'dotenv'

Dotenv.load

# ============================================================================
# SECTION 1: CONFIGURATION - Customize these values for your needs
# ============================================================================

##
# Default transcription model to use when none is specified.
# Options: "nova-3", "nova-2", "nova", "enhanced", "base"
# See: https://developers.deepgram.com/docs/models-languages-overview
DEFAULT_MODEL = 'nova-3'

# Server configuration — overridable via environment variables
set :port, ENV.fetch('PORT', 8081).to_i
set :bind, ENV.fetch('HOST', '0.0.0.0')

# ============================================================================
# SECTION 2: SESSION AUTH - JWT tokens for production security
# ============================================================================

##
# Session secret for signing JWTs.
# Auto-generated if not set via env.
SESSION_SECRET = ENV.fetch('SESSION_SECRET', SecureRandom.hex(32))

# JWT expiry time (1 hour)
JWT_EXPIRY = 3600

##
# Sinatra helper that validates JWT from Authorization header.
# Halts with 401 JSON error if token is missing or invalid.
helpers do
  def require_session!
    auth_header = request.env['HTTP_AUTHORIZATION']

    unless auth_header&.start_with?('Bearer ')
      halt 401, { 'Content-Type' => 'application/json' }, JSON.generate(
        error: {
          type: 'AuthenticationError',
          code: 'MISSING_TOKEN',
          message: 'Authorization header with Bearer token is required'
        }
      )
    end

    token = auth_header.sub('Bearer ', '')
    begin
      JWT.decode(token, SESSION_SECRET, true, algorithm: 'HS256')
    rescue JWT::ExpiredSignature
      halt 401, { 'Content-Type' => 'application/json' }, JSON.generate(
        error: {
          type: 'AuthenticationError',
          code: 'INVALID_TOKEN',
          message: 'Session expired, please refresh the page'
        }
      )
    rescue JWT::DecodeError
      halt 401, { 'Content-Type' => 'application/json' }, JSON.generate(
        error: {
          type: 'AuthenticationError',
          code: 'INVALID_TOKEN',
          message: 'Invalid session token'
        }
      )
    end
  end
end

# ============================================================================
# SECTION 3: API KEY LOADING - Load Deepgram API key from .env
# ============================================================================

##
# Loads the Deepgram API key from environment variables.
# Exits with a helpful error message if not found.
def load_api_key
  api_key = ENV['DEEPGRAM_API_KEY']

  if api_key.nil? || api_key.empty?
    warn "\n  ERROR: Deepgram API key not found!\n"
    warn "Please set your API key using one of these methods:\n"
    warn "1. Create a .env file (recommended):"
    warn "   DEEPGRAM_API_KEY=your_api_key_here\n"
    warn "2. Environment variable:"
    warn "   export DEEPGRAM_API_KEY=your_api_key_here\n"
    warn "Get your API key at: https://console.deepgram.com\n"
    exit 1
  end

  api_key
end

API_KEY = load_api_key

# ============================================================================
# SECTION 4: SETUP - CORS configuration
# ============================================================================

# Enable CORS (wildcard is safe — same-origin via Vite proxy / Caddy in production)
configure do
  enable :cross_origin
end

before do
  response.headers['Access-Control-Allow-Origin'] = '*'
end

options '*' do
  response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
  response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
  200
end

# ============================================================================
# SECTION 5: HELPER FUNCTIONS - Response utilities
# ============================================================================

##
# Formats error responses in a consistent structure.
#
# @param message [String] Error message
# @param status_code [Integer] HTTP status code
# @param code [String] Error code
# @return [Hash] Formatted error response
def format_error_response(message, status_code = 500, code = nil)
  err_type = status_code == 400 ? 'ValidationError' : 'TranscriptionError'
  code ||= status_code == 400 ? 'MISSING_INPUT' : 'TRANSCRIPTION_FAILED'

  {
    error: {
      type: err_type,
      code: code,
      message: message,
      details: {
        originalError: message
      }
    }
  }
end

# ============================================================================
# SECTION 6: DEEPGRAM API CLIENT - Direct HTTP calls to Deepgram REST API
# ============================================================================

##
# Sends audio bytes to the Deepgram /v1/listen endpoint and returns the
# parsed JSON response. Query parameters control model selection and
# feature flags.
#
# @param audio_data [String] Raw audio bytes
# @param params [Hash] Query parameters (model, language, etc.)
# @return [Hash] Parsed Deepgram API response
def call_deepgram_transcription(audio_data, params)
  uri = URI('https://api.deepgram.com/v1/listen')

  # Build query string from params
  query_parts = params.reject { |_, v| v.nil? || v.empty? }.map { |k, v| "#{k}=#{v}" }
  uri.query = query_parts.join('&') unless query_parts.empty?

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 120
  http.open_timeout = 30

  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Token #{API_KEY}"
  req['Content-Type'] = 'application/octet-stream'
  req.body = audio_data

  response = http.request(req)

  unless response.is_a?(Net::HTTPSuccess)
    raise "Deepgram API returned status #{response.code}: #{response.body}"
  end

  JSON.parse(response.body)
end

# ============================================================================
# SECTION 7: RESPONSE FORMATTING - Shape Deepgram responses for the frontend
# ============================================================================

##
# Extracts the relevant fields from the raw Deepgram API response and
# returns a simplified structure the frontend expects.
#
# @param dg_response [Hash] Raw Deepgram API response
# @param model_name [String] Model name used for transcription
# @return [Hash] Formatted response
def format_transcription_response(dg_response, model_name)
  result = dg_response.dig('results', 'channels', 0, 'alternatives', 0)

  raise 'No transcription results returned from Deepgram' unless result

  metadata = {
    model_uuid: dg_response.dig('metadata', 'model_uuid'),
    request_id: dg_response.dig('metadata', 'request_id'),
    model_name: model_name
  }

  response = {
    transcript: result['transcript'] || '',
    words: result['words'] || [],
    metadata: metadata
  }

  # Add optional duration if present
  duration = dg_response.dig('metadata', 'duration')
  response[:duration] = duration if duration

  response
end

# ============================================================================
# SECTION 8: SESSION ROUTES - Auth endpoints (unprotected)
# ============================================================================

##
# GET /api/session - Issues a signed JWT for session authentication.
get '/api/session' do
  content_type :json

  now = Time.now.to_i
  payload = {
    iat: now,
    exp: now + JWT_EXPIRY
  }

  token = JWT.encode(payload, SESSION_SECRET, 'HS256')
  JSON.generate(token: token)
end

# ============================================================================
# SECTION 9: API ROUTES - Define your API endpoints here
# ============================================================================

##
# POST /api/transcription
#
# Main transcription endpoint. Accepts audio file uploads via
# multipart/form-data with a 'file' field.
#
# Query params: model, language, smart_format, diarize, punctuate,
#               paragraphs, utterances, filler_words
#
# Protected by JWT session auth (require_session! helper).
post '/api/transcription' do
  content_type :json
  require_session!

  # Read uploaded file
  unless params[:file] && params[:file][:tempfile]
    status 400
    return JSON.generate(
      format_error_response('Either file or url must be provided', 400, 'MISSING_INPUT')
    )
  end

  audio_data = params[:file][:tempfile].read

  # Build query parameters
  model = params[:model] || request.params['model'] || DEFAULT_MODEL
  language = params[:language] || request.params['language'] || 'en'
  smart_format = params[:smart_format] || request.params['smart_format'] || 'true'

  dg_params = {
    'model' => model,
    'language' => language,
    'smart_format' => smart_format
  }

  # Optional boolean feature flags
  %w[diarize punctuate paragraphs utterances filler_words].each do |key|
    val = params[key] || request.params[key]
    dg_params[key] = val if val && !val.empty?
  end

  # Call Deepgram REST API
  begin
    dg_response = call_deepgram_transcription(audio_data, dg_params)
    response_body = format_transcription_response(dg_response, model)
    JSON.generate(response_body)
  rescue StandardError => e
    logger.error "Transcription error: #{e.message}"
    status 500
    JSON.generate(
      format_error_response('An error occurred during transcription', 500, 'TRANSCRIPTION_FAILED')
    )
  end
end

##
# GET /api/metadata
#
# Returns metadata about this starter application from deepgram.toml.
# Required for standardization compliance.
get '/api/metadata' do
  content_type :json

  begin
    toml_path = File.join(__dir__, 'deepgram.toml')
    config = TomlRB.load_file(toml_path)

    unless config['meta']
      status 500
      return JSON.generate(
        error: 'INTERNAL_SERVER_ERROR',
        message: 'Missing [meta] section in deepgram.toml'
      )
    end

    JSON.generate(config['meta'])
  rescue StandardError => e
    logger.error "Error reading metadata: #{e.message}"
    status 500
    JSON.generate(
      error: 'INTERNAL_SERVER_ERROR',
      message: 'Failed to read metadata from deepgram.toml'
    )
  end
end

##
# GET /health - Simple health-check endpoint.
get '/health' do
  content_type :json
  JSON.generate(status: 'ok')
end

# ============================================================================
# SECTION 10: SERVER START
# ============================================================================

# Print startup banner when run directly
if __FILE__ == $PROGRAM_NAME || app_file == __FILE__
  puts ''
  puts '=' * 70
  puts "  Backend API running at http://localhost:#{settings.port}"
  puts '  GET  /api/session'
  puts '  POST /api/transcription (auth required)'
  puts '  GET  /api/metadata'
  puts '  GET  /health'
  puts '=' * 70
  puts ''
end
