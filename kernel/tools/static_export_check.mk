define check_symbol_export
  $(eval _ARG1 := $(strip $(1)))
  $(eval _ARG2 := $(strip $(2)))
  $(eval _ARG3 := $(strip $(3)))
  $(eval _ARG4 := $(strip $(4)))

  ifneq ($$(shell grep -q -F "$$(_ARG1)" $$(_ARG2); echo $$$$?),0)
      $$(info -- $$(REPO_NAME)/symbol_export: export $$(_ARG3) found)
  else
      $$(info -- You disabled CONFIG_KALLSYMS_ALL and haven't export $$(_ARG3) in your kernel's $$(notdir $$(_ARG2)) file)
      $$(info -- Read: https://bakasu.org/guide/manual-integrate.html#static-symbol-export)
      $$(error You should integrate $$(REPO_NAME) in your kernel. $$(_ARG4))
  endif
endef

# Reason: selinux_hide.  Without KALLSYMS_ALL, selinux_hide.c is compiled
# as a no-op stub, so its private SELinux symbols are not required.
ifdef CONFIG_KALLSYMS_ALL
$(eval $(call check_symbol_export, static ssize_t (*write_op[]), $(srctree)/security/selinux/selinuxfs.c, write_op))
$(eval $(call check_symbol_export, static const struct file_operations sel_handle_status_ops, $(srctree)/security/selinux/selinuxfs.c, sel_handle_status_ops))
endif

# if no selinux_state, we should check sel_mutex and policy_rwlock are NOT static.
# These are used by policydb duplication even when hide is stubbed.
ifneq ($(shell grep -q "struct selinux_state " $(srctree)/security/selinux/include/security.h; echo $$?),0)
ifdef CONFIG_KALLSYMS_ALL
    # Reason: selinux_hide
    $(eval $(call check_symbol_export, static struct page *selinux_status_page, $(srctree)/security/selinux/ss/status.c, selinux_status_page))
    $(eval $(call check_symbol_export, static DEFINE_MUTEX(selinux_status_lock), $(srctree)/security/selinux/ss/status.c, selinux_status_lock))
    $(eval $(call check_symbol_export, static struct sidtab, $(srctree)/security/selinux/ss/services.c, context_struct_compute_av func))
endif

    # Reason: safe policydb patch/dup
    $(eval $(call check_symbol_export, static DEFINE_MUTEX(sel_mutex), $(srctree)/security/selinux/selinuxfs.c, sel_mutex))
    $(eval $(call check_symbol_export, static DEFINE_RWLOCK(policy_rwlock), $(srctree)/security/selinux/ss/services.c, policy_rwlock))
endif

# if kernel < 4.2, we should check selinux_ops has NOT been static.
ifeq ($(shell test $(VERSION) -lt 4 -o \( $(VERSION) -eq 4 -a $(PATCHLEVEL) -lt 2 \) && echo y),y)
    # Reason: We need LSM hooks
    $(eval $(call check_symbol_export, static struct security_operations selinux_ops, $(srctree)/security/selinux/hooks.c, selinux_ops))
endif

ifdef CONFIG_KALLSYMS_ALL
# Reason: selinux_hide
$(eval $(call check_symbol_export, static void security_dump_masked_av, $(srctree)/security/selinux/ss/services.c, security_dump_masked_av func))
$(eval $(call check_symbol_export, static void context_struct_compute_av, $(srctree)/security/selinux/ss/services.c, context_struct_compute_av func))
endif
