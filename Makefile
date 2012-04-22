root.build/ignore-errors = phpbb3
COMMON_CONF = apache-credit

CREDIT_ANCHORTEXT = phpBB Appliance
CREDIT_LOCATION = ~ "^/(?!(adm))"

include $(FAB_PATH)/common/mk/turnkey/lamp.mk
include $(FAB_PATH)/common/mk/turnkey.mk
