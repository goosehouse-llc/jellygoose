# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

- **GitHub:** open the repository's **Security** tab and choose **Report a vulnerability**.
- **Email:** hello@goosehouse.org

Include what you found, how to reproduce it, and what an attacker could do with it. You'll get
a reply within a few days, and credit in the release notes if you'd like it.

## Scope

- The JellyGoose app for Apple TV, iPhone, iPad, Mac and CarPlay (the latest App Store release
  and `main`), with its Top Shelf extension and widgets.
- The website in `site/`.

Problems in Jellyfin or Emby themselves belong with those projects. JellyGoose never sends your
server address, sign-in or token anywhere but your own server, the device's Keychain and (for
settings only, if you turn it on) your own iCloud; a way around that is exactly the kind of
report we want.
