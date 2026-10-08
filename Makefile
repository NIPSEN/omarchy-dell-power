.PHONY: test qml package validate
test:
	node Model.test.js
	node PolicyModel.test.js
	node PresentationModel.test.js
	node ControllerModel.test.js
	python -m unittest discover -s tests -v
qml:
	python tests/check_qml.py
package:
	makepkg --cleanbuild --force --noconfirm
validate:
	omarchy plugin validate .
	git diff --check
