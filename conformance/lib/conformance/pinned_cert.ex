defmodule Conformance.PinnedCert do
  @moduledoc """
  TLS options that trust exactly the given PEM certificates.

  The runner's certificates are self-signed (the client one with CA:FALSE), which OTP
  will not accept as trust anchors, so the certificates are pinned with a verify function.
  """

  def ssl_opts(pem) do
    trusted = for {:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der

    [
      cacerts: trusted,
      verify: :verify_peer,
      verify_fun: {&__MODULE__.verify/3, trusted}
    ]
  end

  @doc false
  def verify(cert, {:bad_cert, reason}, trusted) when reason in [:selfsigned_peer, :unknown_ca] do
    if :public_key.pkix_encode(:OTPCertificate, cert, :otp) in trusted,
      do: {:valid, trusted},
      else: {:fail, {:bad_cert, reason}}
  end

  def verify(_cert, {:bad_cert, _} = reason, _trusted), do: {:fail, reason}
  def verify(_cert, {:extension, _}, trusted), do: {:unknown, trusted}
  def verify(_cert, :valid, trusted), do: {:valid, trusted}
  def verify(_cert, :valid_peer, trusted), do: {:valid, trusted}
end
