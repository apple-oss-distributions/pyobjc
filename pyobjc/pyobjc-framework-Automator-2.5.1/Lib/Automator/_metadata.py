# This file is generated by objective.metadata
#
# Last update: Wed Sep 19 09:41:24 2012

import objc, sys

if sys.maxsize > 2 ** 32:
    def sel32or64(a, b): return b
else:
    def sel32or64(a, b): return a
if sys.byteorder == 'little':
    def littleOrBig(a, b): return a
else:
    def littleOrBig(a, b): return b

misc = {
}
constants = '''$$'''
enums = '''$AMActionApplicationResourceError@-206$AMActionApplicationVersionResourceError@-207$AMActionArchitectureMismatchError@-202$AMActionExceptionError@-213$AMActionExecutionError@-212$AMActionFileResourceError@-208$AMActionInitializationError@-211$AMActionInsufficientDataError@-215$AMActionIsDeprecatedError@-216$AMActionLicenseResourceError@-209$AMActionLinkError@-205$AMActionLoadError@-204$AMActionNotLoadableError@-201$AMActionPropertyListInvalidError@-214$AMActionRequiredActionResourceError@-210$AMActionRuntimeMismatchError@-203$AMConversionFailedError@-302$AMConversionNoDataError@-301$AMConversionNotPossibleError@-300$AMLogLevelDebug@0$AMLogLevelError@3$AMLogLevelInfo@1$AMLogLevelWarn@2$AMNoSuchActionError@-200$AMUserCanceledError@-128$AMWorkflowNewerActionVersionError@-111$AMWorkflowNewerVersionError@-100$AMWorkflowOlderActionVersionError@-112$AMWorkflowPropertyListInvalidError@-101$'''
misc.update({'AMAutomatorErrorDomain': b'com.apple.Automator'.decode("utf-8"), 'AMActionErrorKey': b'AMActionErrorKey'.decode("utf-8")})
r = objc.registerMetaDataForSelector
objc._updatingMetadata(True)
try:
    r(b'AMAction', b'ignoresInput', {'retval': {'type': 'Z'}})
    r(b'AMAction', b'initWithContentsOfURL:error:', {'arguments': {3: {'type_modifier': b'o'}}})
    r(b'AMAction', b'initWithDefinition:fromArchive:', {'arguments': {3: {'type': 'Z'}}})
    r(b'AMAction', b'isStopped', {'retval': {'type': 'Z'}})
    r(b'AMAction', b'logMessageWithLevel:format:', {'arguments': {3: {'printf_format': True}}, 'variadic': True})
    r(b'AMAction', b'runWithInput:error:', {'arguments': {3: {'type_modifier': b'o'}}})
    r(b'AMAction', b'runWithInput:fromAction:error:', {'arguments': {4: {'type_modifier': b'o'}}})
    r(b'AMBundleAction', b'hasView', {'retval': {'type': 'Z'}})
    r(b'AMBundleAction', b'initWithDefinition:fromArchive:', {'arguments': {3: {'type': 'Z'}}})
    r(b'AMShellScriptAction', b'remapLineEndings', {'retval': {'type': 'Z'}})
    r(b'AMWorkflow', b'initWithContentsOfURL:error:', {'arguments': {3: {'type_modifier': b'o'}}})
    r(b'AMWorkflow', b'runWorkflowAtURL:withInput:error:', {'arguments': {4: {'type_modifier': b'o'}}})
    r(b'AMWorkflow', b'setValue:forVariableWithName:', {'retval': {'type': 'Z'}})
    r(b'AMWorkflow', b'writeToURL:error:', {'retval': {'type': 'Z'}, 'arguments': {3: {'type_modifier': b'o'}}})
    r(b'AMWorkflowController', b'canRun', {'retval': {'type': 'Z'}})
    r(b'AMWorkflowController', b'isPaused', {'retval': {'type': 'Z'}})
    r(b'AMWorkflowController', b'isRunning', {'retval': {'type': 'Z'}})
    r(b'AMWorkflowView', b'isEditable', {'retval': {'type': 'Z'}})
    r(b'AMWorkflowView', b'setEditable:', {'arguments': {2: {'type': 'Z'}}})
finally:
    objc._updatingMetadata(False)
r = objc.registerMetaDataForSelector
objc._updatingMetadata(True)
try:
    r(b'NSObject', b'workflowController:didError:', {'retval': {'type': b'v'}, 'arguments': {2: {'type': b'@'}, 3: {'type': b'@'}}})
    r(b'NSObject', b'workflowController:didRunAction:', {'retval': {'type': b'v'}, 'arguments': {2: {'type': b'@'}, 3: {'type': b'@'}}})
    r(b'NSObject', b'workflowController:willRunAction:', {'retval': {'type': b'v'}, 'arguments': {2: {'type': b'@'}, 3: {'type': b'@'}}})
    r(b'NSObject', b'workflowControllerDidRun:', {'retval': {'type': b'v'}, 'arguments': {2: {'type': b'@'}}})
    r(b'NSObject', b'workflowControllerDidStop:', {'retval': {'type': b'v'}, 'arguments': {2: {'type': b'@'}}})
    r(b'NSObject', b'workflowControllerWillRun:', {'retval': {'type': b'v'}, 'arguments': {2: {'type': b'@'}}})
    r(b'NSObject', b'workflowControllerWillStop:', {'retval': {'type': b'v'}, 'arguments': {2: {'type': b'@'}}})
finally:
    objc._updatingMetadata(False)
protocols={'AMWorkflowControllerDelegate': objc.informal_protocol('AMWorkflowControllerDelegate', [objc.selector(None, b'workflowControllerDidStop:', b'v@:@', isRequired=False), objc.selector(None, b'workflowControllerWillRun:', b'v@:@', isRequired=False), objc.selector(None, b'workflowController:willRunAction:', b'v@:@@', isRequired=False), objc.selector(None, b'workflowControllerDidRun:', b'v@:@', isRequired=False), objc.selector(None, b'workflowController:didRunAction:', b'v@:@@', isRequired=False), objc.selector(None, b'workflowControllerWillStop:', b'v@:@', isRequired=False), objc.selector(None, b'workflowController:didError:', b'v@:@@', isRequired=False)])}
expressions = {}

# END OF FILE