# No app-wide keep rules are required. Android components are retained from
# the merged manifest, Flutter plugins are referenced by the generated plugin
# registrant, and libraries supply their own consumer rules where needed.
#
# Keep additions here narrowly scoped to code reached through reflection or
# JNI. Package-wide rules prevent R8 from shrinking, optimizing, or obfuscating
# otherwise eligible release code.
