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
[[ $login_sid =~ ^[0-9a-f]{32}$ ]]
curl "${curl_common[@]}" --location -b "$cookies" -c "$cookies" \
    --data-urlencode username=admin \
    --data-urlencode "password=$TKL_TEST_APP_PASS" \
    --data-urlencode login=Login \
    --data-urlencode "sid=$login_sid" \
    --data-urlencode "redirect=$login_redirect" \
    --data-urlencode "creation_time=$login_creation" \
    --data-urlencode "form_token=$login_token" \
    "$base_url/ucp.php?mode=login" >"$login_post_result"
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

printf '%s\n' phpbb_check=administrator-control-panel
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
    "$base_url/adm/index.php?sid=$sid" >"$admin_login"
if grep -Fq 'name="credential"' "$admin_login"; then
    admin_creation=$(input_value creation_time "$admin_login")
    admin_token=$(input_value form_token "$admin_login")
    admin_redirect=$(input_value redirect "$admin_login")
    admin_sid_field=$(input_value sid "$admin_login")
    admin_credential=$(input_value credential "$admin_login")
    [[ $admin_sid_field =~ ^[0-9a-f]{32}$ ]]
    [[ $admin_credential =~ ^[0-9a-f]{32}$ ]]
    curl "${curl_common[@]}" --location -b "$cookies" -c "$cookies" \
        --data-urlencode username=admin \
        --data-urlencode "password_$admin_credential=$TKL_TEST_APP_PASS" \
        --data-urlencode login=Login \
        --data-urlencode "sid=$admin_sid_field" \
        --data-urlencode "credential=$admin_credential" \
        --data-urlencode "redirect=$admin_redirect" \
        --data-urlencode "creation_time=$admin_creation" \
        --data-urlencode "form_token=$admin_token" \
        "$base_url/adm/index.php?sid=$sid" >"$admin_auth_result"
    if grep -Fq 'The submitted form was invalid' "$admin_auth_result"; then
        echo 'phpbb_admin_login_error=form-rejected' >&2
        exit 1
    fi
    curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
        "$base_url/adm/index.php?sid=$sid" >"$admin_result"
else
    cp "$admin_login" "$admin_result"
fi
grep -Fq 'Administration Control Panel' "$admin_result"
grep -Fq 'id="page-header"' "$admin_result"

stamp=$(date +%s)-$$
forum_name=phpbb-v19-forum-$stamp
topic_subject=phpbb-v19-topic-$stamp
topic_body=phpbb-v19-body-$stamp
forum_url="$base_url/adm/index.php?i=acp_forums&mode=manage&action=add&parent_id=0&forum_name=$forum_name&sid=$sid"

printf '%s\n' phpbb_check=forum-create
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" "$forum_url" >"$forum_form"
forum_creation=$(input_value creation_time "$forum_form")
forum_token=$(input_value form_token "$forum_form")
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
    --data-urlencode forum_parent_id=0 \
    --data-urlencode forum_type=1 \
    --data-urlencode forum_perm_from=2 \
    --data-urlencode "forum_name=$forum_name" \
    --data-urlencode update=Submit \
    --data-urlencode "creation_time=$forum_creation" \
    --data-urlencode "form_token=$forum_token" \
    "$forum_url" >"$forum_result"
grep -Fq 'Forum created successfully' "$forum_result"
forum_id=$(mysql --batch --skip-column-names phpbb \
    --execute="SELECT forum_id FROM phpbb_forums WHERE forum_name='$forum_name'")
[[ $forum_id =~ ^[0-9]+$ ]]
curl "${curl_common[@]}" -b "$cookies" "$base_url/viewforum.php?f=$forum_id" >/tmp/phpbb-v19-forum.html
grep -Fq "$forum_name" /tmp/phpbb-v19-forum.html

printf '%s\n' phpbb_check=topic-create-read
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
    "$base_url/posting.php?mode=post&f=$forum_id" >"$posting_form"
posting_creation=$(input_value creation_time "$posting_form")
posting_token=$(input_value form_token "$posting_form")
curl "${curl_common[@]}" -b "$cookies" -c "$cookies" \
    --data-urlencode "subject=$topic_subject" \
    --data-urlencode "message=$topic_body" \
    --data-urlencode post=Submit \
    --data-urlencode "creation_time=$posting_creation" \
    --data-urlencode "form_token=$posting_token" \
    "$base_url/posting.php?mode=post&f=$forum_id" >"$posting_result"
grep -Fq 'This message has been posted successfully' "$posting_result"
topic_id=$(mysql --batch --skip-column-names phpbb \
    --execute="SELECT topic_id FROM phpbb_topics WHERE forum_id=$forum_id AND topic_title='$topic_subject'")
[[ $topic_id =~ ^[0-9]+$ ]]
curl "${curl_common[@]}" -b "$cookies" "$base_url/viewtopic.php?t=$topic_id" >/tmp/phpbb-v19-topic.html
grep -Fq "$topic_subject" /tmp/phpbb-v19-topic.html
grep -Fq "$topic_body" /tmp/phpbb-v19-topic.html

printf '%s\n' phpbb_check=database
installed=$(php /var/www/phpBB/bin/phpbbcli.php config:get version --no-newline)
test "$installed" = 3.3.17
test "$(mysql --batch --skip-column-names phpbb --execute="SELECT config_value FROM phpbb_config WHERE config_name='version'")" = "$installed"
test "$(mysql --batch --skip-column-names phpbb --execute="SELECT COUNT(*) FROM phpbb_posts WHERE topic_id=$topic_id AND post_subject='$topic_subject' AND post_text='$topic_body'")" = 1
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
