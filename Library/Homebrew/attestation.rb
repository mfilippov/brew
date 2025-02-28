# typed: strict
# frozen_string_literal: true

require "date"
require "json"
require "utils/popen"
require "utils/github/api"
require "exceptions"
require "system_command"

module Homebrew
  module Attestation
    extend SystemCommand::Mixin

    # @api private
    HOMEBREW_CORE_REPO = "Homebrew/homebrew-core"

    # @api private
    GH_ATTESTATION_MIN_VERSION = T.let(Version.new("2.49.0").freeze, Version)

    # @api private
    BACKFILL_REPO = "trailofbits/homebrew-brew-verify"

    # No backfill attestations after this date are considered valid.
    #
    # This date is shortly after the backfill operation for homebrew-core
    # completed, as can be seen here: <https://github.com/trailofbits/homebrew-brew-verify/attestations>.
    #
    # In effect, this means that, even if an attacker is able to compromise the backfill
    # signing workflow, they will be unable to convince a verifier to accept their newer,
    # malicious backfilled signatures.
    #
    # @api private
    BACKFILL_CUTOFF = T.let(DateTime.new(2024, 3, 14).freeze, DateTime)

    # Raised when attestation verification fails.
    #
    # @api private
    class InvalidAttestationError < RuntimeError; end

    # Raised if attestation verification cannot continue due to missing
    # credentials.
    #
    # @api private
    class GhAuthNeeded < RuntimeError; end

    # Returns whether attestation verification is enabled.
    #
    # @api private
    sig { returns(T::Boolean) }
    def self.enabled?
      return false if Homebrew::EnvConfig.no_verify_attestations?
      return true if Homebrew::EnvConfig.verify_attestations?
      return false if GitHub::API.credentials.blank?
      return false if ENV.fetch("CI", false)

      Homebrew::EnvConfig.developer? || Homebrew::EnvConfig.devcmdrun?
    end

    # Returns a path to a suitable `gh` executable for attestation verification.
    #
    # @api private
    sig { returns(Pathname) }
    def self.gh_executable
      # NOTE: We set HOMEBREW_NO_VERIFY_ATTESTATIONS when installing `gh` itself,
      #       to prevent a cycle during bootstrapping. This can eventually be resolved
      #       by vendoring a pure-Ruby Sigstore verifier client.
      @gh_executable ||= T.let(nil, T.nilable(Pathname))
      return @gh_executable if @gh_executable.present?

      with_env(HOMEBREW_NO_VERIFY_ATTESTATIONS: "1") do
        @gh_executable = ensure_executable!("gh", reason: "verifying attestations")

        gh_version = Version.new(system_command!(@gh_executable, args: ["--version"], print_stderr: false)
                                 .stdout.match(/\d+(?:\.\d+)+/i).to_s)
        if gh_version < GH_ATTESTATION_MIN_VERSION
          if Formula["gh"].version < GH_ATTESTATION_MIN_VERSION
            raise "#{@gh_executable} is too old, you must upgrade it to >=#{GH_ATTESTATION_MIN_VERSION} to continue"
          end

          @gh_executable = ensure_formula_installed!("gh", latest: true,
                                                           reason: "verifying attestations").opt_bin/"gh"
        end
      end

      T.must(@gh_executable)
    end

    # Verifies the given bottle against a cryptographic attestation of build provenance.
    #
    # The provenance is verified as originating from `signing_repository`, which is a `String`
    # that should be formatted as a GitHub `owner/repository`.
    #
    # Callers may additionally pass in `signing_workflow`, which will scope the attestation
    # down to an exact GitHub Actions workflow, in
    # `https://github/OWNER/REPO/.github/workflows/WORKFLOW.yml@REF` format.
    #
    # @return [Hash] the JSON-decoded response.
    # @raise [GhAuthNeeded] on any authentication failures
    # @raise [InvalidAttestationError] on any verification failures
    #
    # @api private
    sig {
      params(bottle: Bottle, signing_repo: String,
             signing_workflow: T.nilable(String), subject: T.nilable(String)).returns(T::Hash[T.untyped, T.untyped])
    }
    def self.check_attestation(bottle, signing_repo, signing_workflow = nil, subject = nil)
      cmd = ["attestation", "verify", bottle.cached_download, "--repo", signing_repo, "--format",
             "json"]

      cmd += ["--cert-identity", signing_workflow] if signing_workflow.present?

      # Fail early if we have no credentials. The command below invariably
      # fails without them, so this saves us a network roundtrip before
      # presenting the user with the same error.
      credentials = GitHub::API.credentials
      raise GhAuthNeeded, "missing credentials" if credentials.blank?

      begin
        result = system_command!(gh_executable, args: cmd, env: { "GH_TOKEN" => credentials },
                                 secrets: [credentials], print_stderr: false, chdir: HOMEBREW_TEMP)
      rescue ErrorDuringExecution => e
        # Even if we have credentials, they may be invalid or malformed.
        raise GhAuthNeeded, "invalid credentials" if e.status.exitstatus == 4

        raise InvalidAttestationError, "attestation verification failed: #{e}"
      end

      begin
        attestations = JSON.parse(result.stdout)
      rescue JSON::ParserError
        raise InvalidAttestationError, "attestation verification returned malformed JSON"
      end

      # `gh attestation verify` returns a JSON array of one or more results,
      # for all attestations that match the input's digest. We want to additionally
      # filter these down to just the attestation whose subject matches the bottle's name.
      subject = bottle.filename.to_s if subject.blank?

      attestation = if bottle.tag.to_sym == :all
        # :all-tagged bottles are created by `brew bottle --merge`, and are not directly
        # bound to their own filename (since they're created by deduplicating other filenames).
        # To verify these, we parse each attestation subject and look for one with a matching
        # formula (name, version), but not an exact tag match.
        # This is sound insofar as the signature has already been verified. However,
        # longer term, we should also directly attest to `:all`-tagged bottles.
        attestations.find do |a|
          actual_subject = a.dig("verificationResult", "statement", "subject", 0, "name")
          actual_subject.start_with? "#{bottle.filename.name}--#{bottle.filename.version}"
        end
      else
        attestations.find do |a|
          a.dig("verificationResult", "statement", "subject", 0, "name") == subject
        end
      end

      raise InvalidAttestationError, "no attestation matches subject" if attestation.blank?

      attestation
    end

    # Verifies the given bottle against a cryptographic attestation of build provenance
    # from homebrew-core's CI, falling back on a "backfill" attestation for older bottles.
    #
    # This is a specialization of `check_attestation` for homebrew-core.
    #
    # @return [Hash] the JSON-decoded response
    # @raise [GhAuthNeeded] on any authentication failures
    # @raise [InvalidAttestationError] on any verification failures
    #
    # @api private
    sig { params(bottle: Bottle).returns(T::Hash[T.untyped, T.untyped]) }
    def self.check_core_attestation(bottle)
      begin
        # Ideally, we would also constrain the signing workflow here, but homebrew-core
        # currently uses multiple signing workflows to produce bottles
        # (e.g. `dispatch-build-bottle.yml`, `dispatch-rebottle.yml`, etc.).
        #
        # We could check each of these (1) explicitly (slow), (2) by generating a pattern
        # to pass into `--cert-identity-regex` (requires us to build up a Go-style regex),
        # or (3) by checking the resulting JSON for the expected signing workflow.
        #
        # Long term, we should probably either do (3) *or* switch to a single reusable
        # workflow, which would then be our sole identity. However, GitHub's
        # attestations currently do not include reusable workflow state by default.
        attestation = check_attestation bottle, HOMEBREW_CORE_REPO
        return attestation
      rescue InvalidAttestationError
        odebug "falling back on backfilled attestation for #{bottle}"

        # Our backfilled attestation is a little unique: the subject is not just the bottle
        # filename, but also has the bottle's hosted URL hash prepended to it.
        # This was originally unintentional, but has a virtuous side effect of further
        # limiting domain separation on the backfilled signatures (by committing them to
        # their original bottle URLs).
        url_sha256 = Digest::SHA256.hexdigest(bottle.url)
        subject = "#{url_sha256}--#{bottle.filename}"

        # We don't pass in a signing workflow for backfill signatures because
        # some backfilled bottle signatures were signed from the 'backfill'
        # branch, and others from 'main' of trailofbits/homebrew-brew-verify
        # so the signing workflow is slightly different which causes some bottles to incorrectly
        # fail when checking their attestation. This shouldn't meaningfully affect security
        # because if somehow someone could generate false backfill attestations
        # from a different workflow we will still catch it because the
        # attestation would have been generated after our cutoff date.
        backfill_attestation = check_attestation bottle, BACKFILL_REPO, nil, subject
        timestamp = backfill_attestation.dig("verificationResult", "verifiedTimestamps",
                                             0, "timestamp")

        raise InvalidAttestationError, "backfill attestation is missing verified timestamp" if timestamp.nil?

        if DateTime.parse(timestamp) > BACKFILL_CUTOFF
          raise InvalidAttestationError, "backfill attestation post-dates cutoff"
        end
      end

      backfill_attestation
    end
  end
end
