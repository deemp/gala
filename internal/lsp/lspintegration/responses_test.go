package lspintegration

import (
	"testing"
)

// JSON-RPC 2.0 requires every successful response to carry a `result` member,
// even when the result is null. The shutdown response used to omit it, and
// clients that follow the spec reject such a response: Claude Code logged
// "The received response has neither a result nor an error property" every
// time it stopped the server.
func TestResponses_ShutdownHasNullResult(t *testing.T) {
	galaBin := findGalaBinary(t)
	dir := writeFixture(t, map[string]string{
		"main.gala": "package main\n\nfunc main() {\n    Println(\"hi\")\n}\n",
	})

	c, err := startLSP(galaBin)
	if err != nil {
		t.Fatal(err)
	}
	defer c.close()
	if _, err := c.call("initialize", map[string]interface{}{
		"processId":    nil,
		"rootUri":      pathToFileURI(dir),
		"capabilities": map[string]interface{}{},
	}); err != nil {
		t.Fatal(err)
	}
	if err := c.notify("initialized", map[string]interface{}{}); err != nil {
		t.Fatal(err)
	}

	resp, err := c.call("shutdown", nil)
	if err != nil {
		t.Fatal(err)
	}
	if errMember, ok := resp["error"]; ok {
		t.Fatalf("shutdown returned an error: %s", errMember)
	}
	result, ok := resp["result"]
	if !ok {
		t.Fatalf("shutdown response has no result member: %v", resp)
	}
	if string(result) != "null" {
		t.Errorf("shutdown result = %s, want null", result)
	}
}
