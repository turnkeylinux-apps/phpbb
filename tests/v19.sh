#!/bin/bash
set -euo pipefail

: "${TKL_TEST_APP_PASS:?TKL_TEST_APP_PASS is required}"
: "${TKL_TEST_RESULT:?TKL_TEST_RESULT is required}"

base_url=https://localhost
cookies=/tmp/phpbb-v19.cookies
login_page=/tmp/phpbb-v19-login.html
login_post_result=/tmp/phpbb-v19-login-post-result.html
login_result=/tmp/phpbb-v19-login-result.html
admin_login=/tmp/phpbb-v19-admin-login.html
admin_auth_result=/tmp/phpbb-v19-admin-auth-result.html
admin_result=/tmp/phpbb-v19-admin-result.html
forum_admin=/tmp/phpbb-v19-forum-admin.html
forum_form=/tmp/phpbb-v19-forum-form.html
forum_result=/tmp/phpbb-v19-forum-result.html
posting_form=/tmp/phpbb-v19-posting-form.html
posting_result=/tmp/phpbb-v19-posting-result.html
update_result=/tmp/phpbb-v19-update-check.txt
curl_common=(
    --insecure
    --fail
    --silent
    --show-error
    --resolve localhost:80:127.0.0.1
    --resolve localhost:443:127.0.0.1
)

input_value() {
    local name=$1
    local file=$2
    python3 - "$name" "$file" <<'PY'
from html.parser import HTMLParser
import html
import sys


class InputFinder(HTMLParser):
    value = None

    def handle_starttag(self, tag, attrs):
        if tag != "input" or self.value is not None:
            return
        fields = dict(attrs)
        if fields.get("name") == sys.argv[1]:
            self.value = fields.get("value", "")


parser = InputFinder()
with open(sys.argv[2], encoding="utf-8") as source:
    parser.feed(source.read())
if parser.value is None:
    raise SystemExit(f"missing input {sys.argv[1]} in {sys.argv[2]}")
print(html.unescape(parser.value))
PY
}

form_action_url() {
    local form_id=$1
    local file=$2
    local current_url=${3:-}
    python3 - "$form_id" "$file" "$base_url/" "$current_url" <<'PY'
from html.parser import HTMLParser
from urllib.parse import urljoin
import sys


class FormFinder(HTMLParser):
    action = None
    found = False

    def handle_starttag(self, tag, attrs):
        if tag != "form" or self.found:
            return
        fields = dict(attrs)
        if fields.get("id") == sys.argv[1]:
            self.found = True
            self.action = fields.get("action", "")


parser = FormFinder()
with open(sys.argv[2], encoding="utf-8") as source:
    parser.feed(source.read())
if not parser.found:
    raise SystemExit(f"missing form {sys.argv[1]} in {sys.argv[2]}")
if not parser.action and not sys.argv[4]:
    raise SystemExit(f"missing action for form {sys.argv[1]} in {sys.argv[2]}")
print(urljoin(sys.argv[4] or sys.argv[3], parser.action or sys.argv[4]))
PY
}

hidden_form_data() {
    local form_id=$1
    local file=$2
    python3 - "$form_id" "$file" <<'PY'
from html.parser import HTMLParser
from urllib.parse import urlencode
import sys


class HiddenInputFinder(HTMLParser):
    def __init__(self):
        super().__init__()
        self.fields = []
        self.in_form = False

    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        if tag == "form":
            self.in_form = fields.get("id") == sys.argv[1]
        elif (self.in_form and tag == "input"
              and fields.get("type", "").lower() == "hidden"
              and "name" in fields):
            self.fields.append((fields["name"], fields.get("value", "")))

    def handle_endtag(self, tag):
        if tag == "form" and self.in_form:
            self.in_form = False


parser = HiddenInputFinder()
with open(sys.argv[2], encoding="utf-8") as source:
    parser.feed(source.read())
if not parser.fields:
    raise SystemExit(f"missing hidden inputs for form {sys.argv[1]} in {sys.argv[2]}")
print(urlencode(parser.fields))
PY
}

session_cookie_sid() {
    awk -F '\t' '
        $6 ~ /^phpbb3_.*_sid$/ { value = $7 }
        END { if (value == "") exit 1; print value }
    ' "$cookies"
}

wait_for_form_time() {
    local creation_time=$1
    while (( $(date +%s) <= creation_time )); do
        sleep 0.1
    done
}

forum_manage_url() {
    local file=$1
    python3 - "$file" "$base_url/adm/" <<'PY'
from html.parser import HTMLParser
from urllib.parse import parse_qs, urljoin, urlparse
import sys


class ForumLinkFinder(HTMLParser):
    href = None

    def handle_starttag(self, tag, attrs):
        if tag != "a" or self.href is not None:
            return
        href = dict(attrs).get("href", "")
        query = parse_qs(urlparse(href).query)
        if (query.get("mode") == ["manage"]
                and any("forum" in value for value in query.get("i", []))):
            self.href = href


parser = ForumLinkFinder()
with open(sys.argv[1], encoding="utf-8") as source:
    parser.feed(source.read())
if not parser.href:
    raise SystemExit(f"missing Forum Administration link in {sys.argv[1]}")
print(urljoin(sys.argv[2], parser.href))
PY
}

forum_tab_url() {
    local file=$1
    python3 - "$file" "$base_url/adm/" <<'PY'
from html.parser import HTMLParser
from urllib.parse import urljoin
import sys


class ForumTabFinder(HTMLParser):
    href = None
    current_href = None
    text = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self.current_href = dict(attrs).get("href", "")
            self.text = []

    def handle_data(self, data):
        if self.current_href is not None:
            self.text.append(data)

    def handle_endtag(self, tag):
        if tag != "a" or self.current_href is None:
            return
        if " ".join("".join(self.text).split()).casefold() == "forums":
            self.href = self.current_href
        self.current_href = None
        self.text = []


parser = ForumTabFinder()
with open(sys.argv[1], encoding="utf-8") as source:
    parser.feed(source.read())
if not parser.href:
    raise SystemExit(f"missing Forums tab in {sys.argv[1]}")
print(urljoin(sys.argv[2], parser.href))
PY
}

admin_sid() {
    local file=$1
    python3 - "$file" <<'PY'
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlparse
import html
import sys


class AdminLinkFinder(HTMLParser):
    sid = None

    def handle_starttag(self, tag, attrs):
        if tag != "a" or self.sid is not None:
            return
        href = html.unescape(dict(attrs).get("href", ""))
        parsed = urlparse(href)
        if parsed.path.endswith("/adm/index.php") or parsed.path == "./adm/index.php":
            values = parse_qs(parsed.query).get("sid", [])
            if values:
                self.sid = values[0]


parser = AdminLinkFinder()
with open(sys.argv[1], encoding="utf-8") as source:
    parser.feed(source.read())
if not parser.sid:
    raise SystemExit(f"missing Administration Control Panel SID in {sys.argv[1]}")
print(parser.sid)
PY
}

printf '%s\n' phpbb_check=services
systemctl --quiet is-active apache2.service mariadb.service postfix.service webmin.service multi-user.target
grep -Fq '[20regen-phpbb-secrets] successfully completed' /var/log/inithooks.log
grep -Fq '[40phpbb] successfully completed' /var/log/inithooks.log
test -d /var/www/phpBB
test -d /usr/share/webmin/apache
test -d /usr/share/webmin/mysql
test -d /usr/share/webmin/phpini
ss -ltn | grep -Eq '127\.0\.0\.1:25[[:space:]]'
test "$(mysql --batch --skip-column-names phpbb --execute="SELECT config_value FROM phpbb_config WHERE config_name='server_name'")" = localhost
test "$(mysql --batch --skip-column-names phpbb --execute="SELECT config_value FROM phpbb_config WHERE config_name='cookie_domain'")" = localhost
admin_hash=$(mysql --batch --skip-column-names phpbb \
    --execute="SELECT user_password FROM phpbb_users WHERE username_clean='admin'")
if ! php -r 'exit(password_verify(getenv("TKL_TEST_APP_PASS"), trim(stream_get_contents(STDIN))) ? 0 : 1);' \
        <<<"$admin_hash"; then
    echo 'phpbb_login_error=stored-password-rejected' >&2
    exit 1
fi

printf '%s\n' phpbb_check=https
curl "${curl_common[@]}" "$base_url/" >/tmp/phpbb-v19-index.html
grep -Fq 'Welcome to phpBB' /tmp/phpbb-v19-index.html
curl --insecure --fail --silent --show-error https://127.0.0.1:12322/ >/tmp/phpbb-v19-adminer.html
grep -Eiq 'Adminer|Login' /tmp/phpbb-v19-adminer.html

printf '%s\n' phpbb_check=administrator-login
curl "${curl_common[@]}" -c "$cookies" "$base_url/ucp.php?mode=login" >"$login_page"
if ! awk -F '\t' '$6 ~ /^phpbb3_.*_sid$/ { found = 1 } END { exit !found }' "$cookies"; then
    echo 'phpbb_login_error=session-cookie-rejected' >&2
    exit 1
fi
login_creation=$(input_value creation_time "$login_page")
login_token=$(input_value form_token "$login_page")
login_redirect=$(input_value redirect "$login_page")
login_sid=$(input_value sid "$login_page")
login_action=$(form_action_url login "$login_page")
login_hidden=$(hidden_form_data login "$login_page")
[[ $login_sid =~ ^[0-9a-f]{32}$ ]]
[[ $login_creation =~ ^[0-9]+$ ]]
test -n "$login_token"
test -n "$login_redirect"
if test "$(session_cookie_sid)" != "$login_sid"; then
    echo 'phpbb_login_error=session-state-mismatch' >&2
    exit 1
fi
wait_for_form_time "$login_creation"
curl "${curl_common[@]}" --location -b "$cookies" -c "$cookies" \
    --data "$login_hidden" \
    --data-urlencode username=admin \
    --data-urlencode "password=$TKL_TEST_APP_PASS" \
    --data-urlencode login=Login \
    "$login_action" >"$login_post_result"
if grep -Fq 'The specified username or password is incorrect' "$login_post_result"; then
    echo 'phpbb_login_error=credentials-rejected' >&2
    exit 1
elif grep -Fq 'The submitted form was invalid' "$login_post_result"; then
    echo 'phpbb_login_error=form-rejected' >&2
    exit 1
fi
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" "$base_url/" >"$login_result"
if ! grep -Fq 'mode=logout' "$login_result"; then
    echo 'phpbb_login_error=session-not-established' >&2
    exit 1
fi
grep -Fq 'Administration Control Panel' "$login_result"
sid=$(admin_sid "$login_result")
if test "$(session_cookie_sid)" != "$sid"; then
    echo 'phpbb_admin_login_error=session-link-mismatch' >&2
    exit 1
fi

printf '%s\n' phpbb_check=administrator-control-panel
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
    "$base_url/adm/index.php?sid=$sid" >"$admin_login"
if grep -Fq 'name="credential"' "$admin_login"; then
    admin_creation=$(input_value creation_time "$admin_login")
    admin_token=$(input_value form_token "$admin_login")
    admin_redirect=$(input_value redirect "$admin_login")
    admin_sid_field=$(input_value sid "$admin_login")
    admin_credential=$(input_value credential "$admin_login")
    admin_action=$(form_action_url login "$admin_login" \
        "$base_url/adm/index.php?sid=$sid")
    admin_hidden=$(hidden_form_data login "$admin_login")
    [[ $admin_sid_field =~ ^[0-9a-f]{32}$ ]]
    [[ $admin_credential =~ ^[0-9a-f]{32}$ ]]
    [[ $admin_creation =~ ^[0-9]+$ ]]
    test -n "$admin_token"
    test -n "$admin_redirect"
    if test "$admin_sid_field" != "$sid" || \
            test "$(session_cookie_sid)" != "$admin_sid_field"; then
        echo 'phpbb_admin_login_error=session-state-mismatch' >&2
        exit 1
    fi
    admin_form_salt=$(mysql --batch --skip-column-names phpbb \
        --execute="SELECT user_form_salt FROM phpbb_users WHERE username_clean='admin'")
    admin_expected_token=$(printf '%s%s%s' \
        "$admin_creation" "$admin_form_salt" login | sha1sum | awk '{print $1}')
    if test "$admin_token" != "$admin_expected_token"; then
        echo 'phpbb_admin_login_error=rendered-token-mismatch' >&2
        exit 1
    fi
    wait_for_form_time "$admin_creation"
    curl "${curl_common[@]}" --location -b "$cookies" -c "$cookies" \
        --data "$admin_hidden" \
        --data-urlencode username=admin \
        --data-urlencode "password_$admin_credential=$TKL_TEST_APP_PASS" \
        --data-urlencode login=Login \
        "$admin_action" >"$admin_auth_result"
    if grep -Fq 'The submitted form was invalid' "$admin_auth_result"; then
        echo 'phpbb_admin_login_error=form-rejected' >&2
        exit 1
    elif grep -Fq 'incorrect password' "$admin_auth_result"; then
        echo 'phpbb_admin_login_error=credential-rejected' >&2
        exit 1
    elif grep -Fq 'maximum allowed number of login attempts' "$admin_auth_result"; then
        echo 'phpbb_admin_login_error=rate-limited' >&2
        exit 1
    elif grep -Fq 'name="credential"' "$admin_auth_result"; then
        echo 'phpbb_admin_login_error=authentication-rejected' >&2
        exit 1
    fi
    sid=$(session_cookie_sid)
    [[ $sid =~ ^[0-9a-f]{32}$ ]]
    curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
        "$base_url/adm/index.php?sid=$sid" >"$admin_result"
else
    cp "$admin_login" "$admin_result"
fi
if grep -Fq 'name="credential"' "$admin_result"; then
    echo 'phpbb_admin_login_error=session-not-established' >&2
    exit 1
fi
grep -Fq 'Administration Control Panel' "$admin_result"
grep -Fq 'id="page-header"' "$admin_result"
grep -Fq 'id="tabs"' "$admin_result"
grep -Fq 'id="acp"' "$admin_result"

stamp=$(date +%s)-$$
forum_name=phpbb-v19-forum-$stamp
topic_subject=phpbb-v19-topic-$stamp
topic_body=phpbb-v19-body-$stamp
forum_tab="$(forum_tab_url "$admin_result")"
curl "${curl_common[@]}" --location -b "$cookies" -c "$cookies" \
    "$forum_tab" >"$forum_admin"
forum_url="$(forum_manage_url "$forum_admin")&action=add&parent_id=0"

printf '%s\n' phpbb_check=forum-create
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" "$forum_url" >"$forum_form"
forum_creation=$(input_value creation_time "$forum_form")
forum_token=$(input_value form_token "$forum_form")
forum_action=$(form_action_url forumedit "$forum_form" "$forum_url")
forum_hidden=$(hidden_form_data forumedit "$forum_form")
[[ $forum_creation =~ ^[0-9]+$ ]]
test -n "$forum_token"
forum_form_salt=$(mysql --batch --skip-column-names phpbb \
    --execute="SELECT user_form_salt FROM phpbb_users WHERE username_clean='admin'")
forum_expected_token=$(printf '%s%s%s' \
    "$forum_creation" "$forum_form_salt" acp_forums | sha1sum | awk '{print $1}')
if test "$forum_token" != "$forum_expected_token"; then
    echo 'phpbb_forum_error=rendered-token-mismatch' >&2
    exit 1
fi
permission_source=$(mysql --batch --skip-column-names phpbb \
    --execute='SELECT forum_id FROM phpbb_forums WHERE forum_type=1 ORDER BY forum_id LIMIT 1')
[[ $permission_source =~ ^[0-9]+$ ]]
wait_for_form_time "$forum_creation"
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
    --data "$forum_hidden" \
    --data-urlencode forum_parent_id=0 \
    --data-urlencode forum_type=1 \
    --data-urlencode "forum_perm_from=$permission_source" \
    --data-urlencode "forum_name=$forum_name" \
    --data-urlencode update=Submit \
    "$forum_action" >"$forum_result"
if grep -Fq 'The submitted form was invalid' "$forum_result"; then
    echo 'phpbb_forum_error=form-rejected' >&2
    exit 1
elif ! grep -Fq 'Forum created successfully' "$forum_result"; then
    echo 'phpbb_forum_error=creation-not-confirmed' >&2
    exit 1
fi
forum_id=$(mysql --batch --skip-column-names phpbb \
    --execute="SELECT forum_id FROM phpbb_forums WHERE forum_name='$forum_name'")
if [[ ! $forum_id =~ ^[0-9]+$ ]]; then
    echo 'phpbb_forum_error=database-row-missing' >&2
    exit 1
fi
if ! curl "${curl_common[@]}" -b "$cookies" \
        "$base_url/viewforum.php?f=$forum_id" >/tmp/phpbb-v19-forum.html; then
    echo 'phpbb_forum_error=read-request-failed' >&2
    exit 1
elif ! grep -Fq "$forum_name" /tmp/phpbb-v19-forum.html; then
    echo 'phpbb_forum_error=read-content-missing' >&2
    exit 1
fi

printf '%s\n' phpbb_check=topic-create-read
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
    "$base_url/posting.php?mode=post&f=$forum_id" >"$posting_form"
posting_creation=$(input_value creation_time "$posting_form")
posting_token=$(input_value form_token "$posting_form")
posting_action=$(form_action_url postform "$posting_form")
posting_hidden=$(hidden_form_data postform "$posting_form")
[[ $posting_creation =~ ^[0-9]+$ ]]
test -n "$posting_token"
posting_expected_token=$(printf '%s%s%s' \
    "$posting_creation" "$forum_form_salt" posting | sha1sum | awk '{print $1}')
if test "$posting_token" != "$posting_expected_token"; then
    echo 'phpbb_topic_error=rendered-token-mismatch' >&2
    exit 1
fi
wait_for_form_time "$posting_creation"
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
    --data "$posting_hidden" \
    --data-urlencode "subject=$topic_subject" \
    --data-urlencode "message=$topic_body" \
    --data-urlencode post=Submit \
    "$posting_action" >"$posting_result"
if grep -Fq 'The submitted form was invalid' "$posting_result"; then
    echo 'phpbb_topic_error=form-rejected' >&2
    exit 1
fi
topic_id=$(mysql --batch --skip-column-names phpbb \
    --execute="SELECT topic_id FROM phpbb_topics WHERE forum_id=$forum_id AND topic_title='$topic_subject'")
if [[ ! $topic_id =~ ^[0-9]+$ ]]; then
    echo 'phpbb_topic_error=database-row-missing' >&2
    exit 1
fi
if ! curl "${curl_common[@]}" -b "$cookies" \
        "$base_url/viewtopic.php?t=$topic_id" >/tmp/phpbb-v19-topic.html; then
    echo 'phpbb_topic_error=read-request-failed' >&2
    exit 1
elif ! grep -Fq "$topic_subject" /tmp/phpbb-v19-topic.html || \
        ! grep -Fq "$topic_body" /tmp/phpbb-v19-topic.html; then
    echo 'phpbb_topic_error=read-content-missing' >&2
    exit 1
fi

printf '%s\n' phpbb_check=database
installed=$(php /var/www/phpBB/bin/phpbbcli.php config:get version --no-newline)
test "$installed" = 3.3.17
test "$(mysql --batch --skip-column-names phpbb --execute="SELECT config_value FROM phpbb_config WHERE config_name='version'")" = "$installed"
test "$(mysql --batch --skip-column-names phpbb --execute="SELECT COUNT(*) FROM phpbb_posts WHERE topic_id=$topic_id AND post_subject='$topic_subject'")" = 1
test "$(mysql --batch --skip-column-names phpbb --execute="SELECT config_value FROM phpbb_config WHERE config_name='allow_avatar_upload'")" = 1

printf '%s\n' phpbb_check=updater
before=$installed
turnkey-phpbb-check-update >"$update_result"
after=$(php /var/www/phpBB/bin/phpbbcli.php config:get version --no-newline)
test "$after" = "$before"
grep -Fxq "installed=$installed" "$update_result"
grep -Eq '^latest=[0-9]+\.[0-9]+\.[0-9]+$' "$update_result"
grep -Fxq 'channel=https://download.phpbb.com/pub/release/3.3/' "$update_result"
grep -Eq '^package=https://download\.phpbb\.com/pub/release/3\.3/[0-9]+\.[0-9]+\.[0-9]+/phpBB-[0-9]+\.[0-9]+\.[0-9]+\.zip$' "$update_result"
grep -Eq '^sha256=[0-9a-f]{64}$' "$update_result"

php_package=$(dpkg-query -W -f='${Version}' php-cli)
mariadb_package=$(dpkg-query -W -f='${Version}' mariadb-server)
apache_package=$(dpkg-query -W -f='${Version}' apache2)
cat >"$TKL_TEST_RESULT" <<EOF
package_source=official phpBB 3.3.17 archive pinned by published SHA-256; Debian Trixie php-cli $php_package, mariadb-server $mariadb_package, apache2 $apache_package
installed_version=$installed
runtime_checks=normal init, firstboot secrets and administrator configuration, Apache, MariaDB, Postfix, Webmin, HTTPS phpBB and Adminer, HTTPS administrator and ACP login, forum and topic create/read round trip, database state
updater_command=turnkey-phpbb-check-update
updater_result=official stable index and package checksum parsed over HTTPS; installed version unchanged ($installed)
updater_channel=https://download.phpbb.com/pub/release/3.3/
integrity_evidence=build verified phpBB-3.3.17.zip SHA-256 ba1819a53c6a36bb9ebce8d3d0ac6c1b28687d6aa07a2ce9d8c4956da7d38874; updater verified official checksum metadata over HTTPS
EOF
