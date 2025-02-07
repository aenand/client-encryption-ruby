# frozen_string_literal: true

require 'json'
require 'openssl'
require 'base64'
require 'securerandom'
require_relative '../utils/utils'
require_relative '../utils/openssl_rsa_oaep'

module McAPI
  module Encryption
    #
    # JWE Crypto class provide RSA/AES encrypt/decrypt methods
    #
    class JweCrypto
      #
      # Create a new instance with the provided config
      #
      # @param [Hash] config configuration object
      #
      def initialize(config)
        @encoding = config['dataEncoding']
        @cert = OpenSSL::X509::Certificate.new(IO.binread(config['encryptionCertificate']))
        if config['privateKey']
          @private_key = OpenSSL::PKey.read(IO.binread(config['privateKey']))
        elsif config['keyStore']
          @private_key = OpenSSL::PKCS12.new(IO.binread(config['keyStore']), config['keyStorePassword']).key
        end
        @encrypted_value_field_name = config['encryptedValueFieldName'] || 'encryptedData'
        @public_key_fingerprint = compute_public_fingerprint
      end

      #
      # Perform data encryption:
      #
      # @param [String] data json string to encrypt
      #
      # @return [Hash] encrypted data
      #
      def encrypt_data(data:)
        cek = SecureRandom.random_bytes(32)
        iv = SecureRandom.random_bytes(12)

        md = OpenSSL::Digest::SHA256
        encrypted_key = @cert.public_key.public_encrypt_oaep(cek, '', md, md)

        header = generate_header('RSA-OAEP-256', 'A256GCM')
        json_hdr = header.to_json
        auth_data = jwe_encode(json_hdr)

        cipher = OpenSSL::Cipher.new('aes-256-gcm')
        cipher.encrypt
        cipher.key = cek
        cipher.iv = iv
        cipher.padding = 0
        cipher.auth_data = auth_data
        cipher_text = cipher.update(data) + cipher.final

        payload = generate_serialization(json_hdr, encrypted_key, cipher_text, iv, cipher.auth_tag)
        {
          @encrypted_value_field_name => payload
        }
      end

      #
      # Perform data decryption
      #
      # @param [String] encrypted_data encrypted data to decrypt
      #
      # @return [String] Decrypted JSON object
      #
      def decrypt_data(encrypted_data:)
        parts = encrypted_data.split('.')
        encrypted_header, encrypted_key, initialization_vector, cipher_text, authentication_tag = parts

        jwe_header = jwe_decode(encrypted_header)
        encrypted_key = jwe_decode(encrypted_key)
        iv = jwe_decode(initialization_vector)
        cipher_text = jwe_decode(cipher_text)
        cipher_tag = jwe_decode(authentication_tag)

        md = OpenSSL::Digest::SHA256
        cek = @private_key.private_decrypt_oaep(encrypted_key, '', md, md)

        enc_method = JSON.parse(jwe_header)['enc']

        if enc_method == "A256GCM"
          enc_string = "aes-256-gcm"
        elsif enc_method == "A128CBC-HS256"
          cek = cek.byteslice(16, cek.length)
          enc_string = "aes-128-cbc"
        else
          raise Exception, "Encryption method '#{enc_method}' not supported."
        end

        cipher = OpenSSL::Cipher.new(enc_string)
        cipher.decrypt
        cipher.key = cek
        cipher.iv = iv
        cipher.padding = 0
        if enc_method == "A256GCM"
          cipher.auth_data = encrypted_header
          cipher.auth_tag = cipher_tag
        end

        cipher.update(cipher_text) + cipher.final
      end

      private

      #
      # Compute the fingerprint for the provided public key
      #
      # @return [String] the computed fingerprint encoded using the configured encoding
      #
      def compute_public_fingerprint
        OpenSSL::Digest::SHA256.new(@cert.public_key.to_der).to_s
      end

      #
      # Generate the JWE header for the provided encryption algorithm and encryption method
      #
      # @param [String] alg the cryptographic algorithm used to encrypt the value of the CEK
      # @param [String] enc the content encryption algorithm used to perform authenticated encryption on the plaintext
      #
      # @return [Hash] the JWE header
      #
      def generate_header(alg, enc)
        { alg: alg, enc: enc, kid: @public_key_fingerprint, cty: 'application/json' }
      end

      #
      # URL safe Base64 encode the provided value
      #
      # @param [String] value to be encoded
      #
      # @return [String] URL safe Base64 encoded value
      #
      def jwe_encode(value)
        ::Base64.urlsafe_encode64(value).delete('=')
      end

      #
      # URL safe Base64 decode the provided value
      #
      # @param [String] value to be decoded
      #
      # @return [String] URL safe Base64 decoded value
      #
      def jwe_decode(value)
        padlen = 4 - (value.length % 4)
        if padlen < 4
          pad = '=' * padlen
          value += pad
        end
        ::Base64.urlsafe_decode64(value)
      end

      #
      # Generate JWE compact payload from the provided values
      #
      # @param [String] hdr JWE header
      # @param [String] cek content encryption key
      # @param [String] content cipher text
      # @param [String] iv initialization vector
      # @param [String] tag cipher auth tag
      #
      # @return [String] URL safe Base64 decoded value
      #
      def generate_serialization(hdr, cek, content, iv, tag)
        [hdr, cek, iv, content, tag].map { |piece| jwe_encode(piece) }.join '.'
      end
    end
  end
end
