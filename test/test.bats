@test "init creates a root and intermediate cert with the right DNs" {
	run init_from_input
	dump_output_on_fail
	[ "$status" -eq 0 ]

	ROOTCERT=$(openssl x509 -in /tmp/spki/certs/ca.cert.pem -noout -text)
	echo "$ROOTCERT" | grep "Issuer: $ROOT_DN" &> /dev/null
	echo "$ROOTCERT" | grep "Subject: $ROOT_DN" &> /dev/null
	INTRMDTCERT=$(openssl x509 -in /tmp/spki/intermediate/certs/intermediate.cert.pem -noout -text)
	echo "$INTRMDTCERT" | grep "Issuer: $ROOT_DN" &> /dev/null
	echo "$INTRMDTCERT" | grep "Subject: $INTERMEDIATE_DN" &> /dev/null
}