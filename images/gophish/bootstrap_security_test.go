// Installed into the upstream models package by the local build script.
package models

import (
	"bytes"
	"strings"
	"testing"

	"github.com/gophish/gophish/auth"
	"github.com/gophish/gophish/config"
	log "github.com/gophish/gophish/logger"
)

func TestBootstrapDoesNotLogPassword(t *testing.T) {
	const password = "synthetic-bootstrap-password-12345"
	t.Setenv(InitialAdminPassword, password)
	var output bytes.Buffer
	oldOutput := log.Logger.Out
	oldDB, oldConf := db, conf
	log.Logger.SetOutput(&output)
	defer func() {
		log.Logger.SetOutput(oldOutput)
		if db != nil && db != oldDB {
			db.Close()
		}
		db, conf = oldDB, oldConf
	}()
	if err := Setup(&config.Config{
		DBName: "sqlite3", DBPath: ":memory:",
		MigrationsPath: "../db/db_sqlite3/migrations/",
	}); err != nil {
		t.Fatal(err)
	}
	user, err := GetUserByUsername("admin")
	if err != nil {
		t.Fatal(err)
	}
	if err := auth.ValidatePassword(password, user.Hash); err != nil {
		t.Fatal("configured bootstrap password did not initialize the account")
	}
	if !user.PasswordChangeRequired {
		t.Fatal("bootstrap must require a password change")
	}
	if strings.Contains(output.String(), password) {
		t.Fatal("bootstrap logs disclosed the configured password")
	}
}
