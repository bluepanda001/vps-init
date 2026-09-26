#!/usr/bin/env bash
optional_cloudflaresub() {
  local enabled=false
  case "cloudflaresub" in
    cf-ws) enabled="${ENABLE_CF_WS}" ;;
    cf-preferred) enabled="${ENABLE_CF_PREFERRED}" ;;
    cloudflaresub) enabled="${ENABLE_CLOUDFLARESUB}" ;;
  esac
  if is_true "$enabled"; then
    die "可选扩展 cloudflaresub 在 V1 中故意不自动部署。核心 Profile 不依赖它；请保持 false，避免把未验证扩展混入基础初始化。"
  fi
}
