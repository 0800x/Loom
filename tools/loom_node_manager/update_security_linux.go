//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

func requirePrivateRootFile(path string) error {
	for _, p := range []string{filepath.Dir(filepath.Dir(path)), filepath.Dir(path), path} {
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 {
			return fmt.Errorf("release approval must be root-owned and not writable by others: %s", p)
		}
		if p == path && (!info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0) {
			return fmt.Errorf("release approval must be a private regular file")
		}
	}
	return nil
}

func dropUpdatePrivileges(cmd *exec.Cmd) error {
	if os.Geteuid() == 0 {
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: 65534, Gid: 65534, Groups: []uint32{}}}
	}
	return nil
}

func prepareUnprivilegedDirectory(root, download string) error {
	// The root-private archive/source siblings stay inaccessible to the worker.
	if err := os.Chmod(root, 0711); err != nil {
		return err
	}
	if os.Geteuid() == 0 {
		return os.Chown(download, 65534, 65534)
	}
	return nil
}

func validatePrivilegedHome(home string) error {
	if os.Geteuid() != 0 {
		return nil
	}
	if home != "/opt/loom-node" {
		return fmt.Errorf("unapproved privileged Node home")
	}
	for _, p := range []string{"/opt", home, filepath.Join(home, "bin"), filepath.Join(home, "bin", "loom-node-manager")} {
		info, err := os.Lstat(p)
		if err != nil {
			return err
		}
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != 0 || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 {
			return fmt.Errorf("unsafe privileged Node path")
		}
	}
	return nil
}
