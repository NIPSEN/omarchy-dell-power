.PHONY: test qml validate sums
test:
	node Model.test.js
	node PolicyModel.test.js
	node PresentationModel.test.js
	node ControllerModel.test.js
	python -m unittest discover -s tests -v
qml:
	python tests/check_qml.py
validate:
	omarchy plugin validate .
	git diff --check
sums:
	sha256sum system/installer.py system/dell-charge-limit system/backend.py system/*.policy > SHA256SUMS
