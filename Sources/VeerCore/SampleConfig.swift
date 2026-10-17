import Foundation

/// Offline demo configuration. Every server and secret is a placeholder.
public enum SampleConfig {
    public static let title = "示例配置.yaml"

    public static let text = """
    # Veer 示例配置：所有节点与密码均为占位，不能连接。
    mixed-port: 7890
    allow-lan: false
    mode: rule
    log-level: info

    proxies:
      - name: "🇯🇵 东京 01"
        type: ss
        server: jp1.example.invalid
        port: 8388
        cipher: aes-128-gcm
        password: "placeholder-password-1"
      - name: "🇺🇸 洛杉矶 01"
        type: ss
        server: us1.example.invalid
        port: 8388
        cipher: aes-128-gcm
        password: "placeholder-password-2"
      - name: "🇭🇰 香港 01"
        type: ss
        server: hk1.example.invalid
        port: 8388
        cipher: aes-128-gcm
        password: "placeholder-password-3"
      - name: Premium-SG-Netflix-Unlock-IEPL-02-高速专线
        type: ss
        server: sg2.example.invalid
        port: 8388
        cipher: aes-128-gcm
        password: "placeholder-password-4"
      - name: Backup Relay
        type: ss
        server: relay.example.invalid
        port: 8388
        cipher: aes-128-gcm
        password: "placeholder-password-5"

    proxy-groups:
      - name: 日本出口
        type: select
        proxies: ["🇯🇵 东京 01"]
      - name: 美国出口
        type: select
        proxies: ["🇺🇸 洛杉矶 01"]
      - name: 香港出口
        type: select
        proxies: ["🇭🇰 香港 01"]
      - name: 自动选择
        type: url-test
        url: https://www.gstatic.com/generate_204
        interval: 300
        proxies: ["🇯🇵 东京 01", "🇺🇸 洛杉矶 01", "🇭🇰 香港 01", Backup Relay]

    rules:
      - DOMAIN-SUFFIX,openai.com,DIRECT
      - DOMAIN-SUFFIX,example.com,DIRECT
      - DOMAIN-KEYWORD,google,美国出口
      - DOMAIN-SUFFIX,github.com,自动选择
      - GEOSITE,cn,DIRECT
      - GEOIP,CN,DIRECT,no-resolve
      - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
      - MATCH,自动选择

    """
}
