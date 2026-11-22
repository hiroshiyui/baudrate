defmodule Ops.NginxSecurityHeadersTest do
  @moduledoc """
  Keeps nginx from overriding the security headers the application chose.

  Phoenix sets `Strict-Transport-Security`, `X-Content-Type-Options`,
  `X-Frame-Options` and `Referrer-Policy` on its own responses, per pipeline:
  feeds, ActivityPub and the media proxy send `Referrer-Policy: no-referrer`
  (`BaudrateWeb.Plugs.ApiHeaders`), stricter than the browser pages. nginx's
  `add_header` appends rather than replaces, and a browser honours the *last*
  Referrer-Policy it can parse — so until 2026-11-22 every proxied response carried
  each header twice, and nginx's `strict-origin-when-cross-origin` overrode
  the application's `no-referrer`.

  The rule this enforces: in every nginx config this repository ships, those
  four headers are added only through a `$baudrate_*` variable that a `map`
  on `$upstream_http_*` leaves empty when Phoenix already sent the header.
  nginx skips an `add_header` whose value is empty, so the baseline reaches
  only responses nginx answers itself (static files, refusals, the 502 page).
  """

  use ExUnit.Case, async: true

  @templates [
    "ansible/roles/nginx/templates/baudrate.conf.j2",
    "doc/examples/nginx.conf.example"
  ]

  @headers %{
    "Strict-Transport-Security" => {"$baudrate_hsts", "strict_transport_security"},
    "X-Content-Type-Options" => {"$baudrate_nosniff", "x_content_type_options"},
    "X-Frame-Options" => {"$baudrate_frame_options", "x_frame_options"},
    "Referrer-Policy" => {"$baudrate_referrer_policy", "referrer_policy"}
  }

  for template <- @templates do
    describe template do
      setup do
        {:ok, conf: File.read!(unquote(template))}
      end

      test "adds each security header only through its fallback variable", %{conf: conf} do
        for {header, {var, _upstream}} <- @headers do
          lines = Regex.scan(~r/^\s*add_header\s+#{header}\s+(\S+)/mi, conf)

          assert lines != [], "#{unquote(template)} no longer adds #{header} anywhere"

          for [line, value] <- lines do
            assert value == var, """
            #{unquote(template)}: `#{String.trim(line)}` adds #{header} with a
            literal value. On a proxied response that duplicates the header
            Phoenix already sent, and for Referrer-Policy the later copy wins.
            Use `#{var}`, which is empty when the upstream sent the header.
            """
          end
        end
      end

      test "each fallback variable is empty when the upstream sent the header", %{conf: conf} do
        for {_header, {var, upstream}} <- @headers do
          name = String.trim_leading(var, "$")

          assert [[_, body]] =
                   Regex.scan(
                     ~r/^map\s+\$upstream_http_#{upstream}\s+\$#{name}\s*\{(.*?)\}/ms,
                     conf
                   ),
                 "#{unquote(template)}: no `map $upstream_http_#{upstream} #{var}`"

          assert body =~ ~r/^\s*default\s+"";/m,
                 "#{unquote(template)}: #{var} must default to \"\" (header present upstream)"

          assert body =~ ~r/^\s*""\s+"[^"]+";/m,
                 "#{unquote(template)}: #{var} must supply the baseline when upstream sent none"
        end
      end
    end
  end
end
