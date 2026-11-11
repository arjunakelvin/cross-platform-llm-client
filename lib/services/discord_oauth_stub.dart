/// Non-web stubs for the Discord OAuth redirect helpers.
void discordOpenUrl(String url) {
  // Opening a browser window is only wired up on web for now.
}

String? discordExtractAuthCode() => null;

String? discordExtractAuthState() => null;

void discordClearRedirectQuery() {}

void discordResetUrl(String path) {}
