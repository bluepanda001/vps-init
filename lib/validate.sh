#!/usr/bin/env bash
validate_config() {
  case "$PROFILE" in base-only|lucky-web|reality-only|nginx-reality|lucky-reality) ;; *) die "PROFILE 无效: $PROFILE" ;; esac
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && ((SSH_PORT>=1 && SSH_PORT<=65535)) || die "SSH_PORT 无效。"

  if profile_has_domain; then
    [[ -n "$ROOT_DOMAIN" ]] || die "$PROFILE 必须设置 ROOT_DOMAIN。"
    [[ "$ROOT_DOMAIN" != *://* && "$ROOT_DOMAIN" != */* && "$ROOT_DOMAIN" == *.* ]] || die "ROOT_DOMAIN 只填写根域名，例如 example.com，不要带协议或路径。"
    [[ "$DNS_PROVIDER" == "cloudflare" ]] || die "V1 仅支持 DNS_PROVIDER=cloudflare。"
  fi

  case "$REALITY_TARGET_MODE" in auto|manual) ;; *) die "REALITY_TARGET_MODE 只能是 auto/manual。" ;; esac
  if profile_has_xui; then
    [[ "$REALITY_TARGET_MODE" != manual || -n "$REALITY_TARGET" ]] || die "manual 模式必须设置 REALITY_TARGET。"
    if [[ "$REALITY_TARGET_MODE" == manual ]]; then
      local reality_target_lc="${REALITY_TARGET,,}"
      if [[ "$reality_target_lc" =~ (^|\.)(cloudflare\.com|cloudflare\.net|workers\.dev|pages\.dev)(:[0-9]+)?$ ]]; then
        die "拒绝把 Cloudflare 共享 CDN 域名作为 Reality Target：鉴权失败流量会被转发到 target，存在被扫描后偷跑流量风险。"
      fi
    fi
    [[ "$REALITY_CANDIDATES" != */* ]] || die "REALITY_CANDIDATES 不接受 CIDR/网段；V1 只做小规模域名候选检测。"
    local candidate_count
    candidate_count="$(awk -F, '{print NF}' <<<"$REALITY_CANDIDATES")"
    (( candidate_count <= 10 )) || die "REALITY_CANDIDATES 最多 10 个候选，避免大范围扫描。"
    local fallback_key fallback_val
    for fallback_key in REALITY_FALLBACK_AFTER_BYTES REALITY_FALLBACK_UPLOAD_BPS REALITY_FALLBACK_UPLOAD_BURST_BPS REALITY_FALLBACK_DOWNLOAD_BPS REALITY_FALLBACK_DOWNLOAD_BURST_BPS; do
      fallback_val="${!fallback_key}"
      [[ "$fallback_val" =~ ^[0-9]+$ ]] || die "${fallback_key} 必须是非负整数。"
    done
  fi

  [[ "$SUBSCRIPTION_PORT" =~ ^[0-9]+$ ]] && ((SUBSCRIPTION_PORT>=1 && SUBSCRIPTION_PORT<=65535)) || die "SUBSCRIPTION_PORT 无效。"
  [[ "${XUI_PANEL_URI_PATH:-/zhg/}" == /* && "${XUI_PANEL_URI_PATH:-/zhg/}" == */ ]] || die "XUI_PANEL_URI_PATH 必须以 / 开头和结尾。"
  if [[ -n "${XUI_SUB_URI_PATH:-}" ]]; then
    [[ "$XUI_SUB_URI_PATH" == /* && "$XUI_SUB_URI_PATH" == */ ]] || die "XUI_SUB_URI_PATH 必须以 / 开头和结尾。"
  fi
  case "$ENABLE_SUBSCRIPTION" in auto|true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) die "ENABLE_SUBSCRIPTION 只能是 auto/true/false。" ;; esac
  case "$SUBSCRIPTION_EXPOSE_MODE" in auto|none|direct-ip-https|nginx-https|lucky-https) ;; *) die "SUBSCRIPTION_EXPOSE_MODE 无效。" ;; esac

  if is_true "$ENABLE_SUBSCRIPTION_RESOLVED"; then
    case "$PROFILE:$SUBSCRIPTION_EXPOSE_MODE_RESOLVED" in
      reality-only:direct-ip-https|nginx-reality:nginx-https|nginx-reality:direct-ip-https|lucky-reality:lucky-https|lucky-reality:direct-ip-https) ;;
      *) die "Profile=${PROFILE} 与订阅暴露模式 ${SUBSCRIPTION_EXPOSE_MODE_RESOLVED} 不匹配。" ;;
    esac
  fi

  case "$ENABLE_DOCKER" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) die "ENABLE_DOCKER 只能是 true/false。" ;; esac
  case "$ENABLE_CF_WS" in true|false|TRUE|FALSE|1|0|yes|no|YES|NO|on|off|ON|OFF) ;; *) die "ENABLE_CF_WS 只能是 true/false。" ;; esac
  if is_true "$ENABLE_CF_WS" && ! profile_has_domain; then
    die "ENABLE_CF_WS=true 需要 nginx-reality 或 lucky-reality 域名 Profile。"
  fi
}
