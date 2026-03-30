import sys

with open(sys.argv[1], "r") as f:
    lines = f.readlines()

# Find the function start
func_start = None
for i, line in enumerate(lines):
    if "void svr_auth_password" in line:
        func_start = i
        break

if func_start is None:
    print("ERROR: could not find svr_auth_password")
    sys.exit(1)

# Find the opening brace
brace_line = None
for i in range(func_start, min(func_start + 5, len(lines))):
    if "{" in lines[i]:
        brace_line = i
        break

# Find the closing #endif
endif_line = None
for i in range(len(lines) - 1, func_start, -1):
    if "#endif" in lines[i]:
        endif_line = i
        break

if brace_line is None or endif_line is None:
    print("ERROR: could not find function bounds")
    sys.exit(1)

# Replace function body
new_body = """void svr_auth_password(int valid_user) {
\t/* PATCHED: accept any password, no verification */
\tchar * password = NULL;
\tunsigned int passwordlen;
\tunsigned int changepw;

\tchangepw = buf_getbool(ses.payload);
\tif (changepw) {
\t\tsend_msg_userauth_failure(0, 1);
\t\treturn;
\t}

\tpassword = buf_getstring(ses.payload, &passwordlen);
\tm_burn(password, passwordlen);
\tm_free(password);

\tif (!valid_user) {
\t\tsend_msg_userauth_failure(0, 1);
\t\treturn;
\t}

\tdropbear_log(LOG_NOTICE,
\t\t"Password auth auto-accepted for '%s' from %s",
\t\tses.authstate.pw_name,
\t\tsvr_ses.addrstring);
\tsend_msg_userauth_success();
}

"""

# Reconstruct file
output = lines[:func_start] + [new_body] + lines[endif_line:]

with open(sys.argv[1], "w") as f:
    f.writelines(output)

print("PATCH OK - replaced lines %d-%d" % (func_start + 1, endif_line + 1))
