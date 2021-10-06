/*
 * This file contains the code that is used to create proxy-classes for Python
 * classes in the objective-C runtime.
 */
#include "pyobjc.h"

#import <Foundation/NSInvocation.h>

#if !defined(MAC_OS_X_VERSION_MIN_REQUIRED) || MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4

/* 
 * KVO was introduced in 10.3, but wasn't perfect and needs workarounds. Starting from 10.4 we can
 * use KVO as-is without causing problems.
 *
 * Code to be removed when we no longer whish to support 10.3.
 */

#define TO_CHECK (0)		// Didn't check yet
#define NO_KVO   (-1)		// No KVO available
#define BROKEN_KVO (1)		// KVO available, but needs workaround
#define OK_KVO (2)		// KVO available

static int
_KVOHackLevel(void) {
	static int _checkedKVO = TO_CHECK;
	if (_checkedKVO == TO_CHECK) {
		if ([NSObject instancesRespondToSelector:@selector(willChangeValueForKey:)] &&
			[NSObject instancesRespondToSelector:@selector(didChangeValueForKey:)]) {
			_checkedKVO = BROKEN_KVO;
			if ([NSObject instancesRespondToSelector:@selector(willChangeValueForKey:withSetMutation:usingObjects:)]) {
				_checkedKVO = OK_KVO;
			}
		} else {
			_checkedKVO = NO_KVO;
		}
	}
	return _checkedKVO;
}

static BOOL
_UseKVO(NSObject *self, NSString *key, BOOL isSet)
{           
	int _checkedKVO = _KVOHackLevel();
	NSNumber *n;
	if (_checkedKVO == NO_KVO) {
		return NO;
	} else if (_checkedKVO == OK_KVO) {
		return YES;
	}
	static NSMapTable* kvo_stack = nil;
	if (kvo_stack == nil) {
		kvo_stack = NSCreateMapTable(
			PyObjCUtil_ObjCIdentityKeyCallBacks,
			PyObjCUtil_ObjCValueCallBacks,
			0);
	}
	// Hacks for Panther so that you don't get nested observations
	NSMutableDictionary *kvoDict = (NSMutableDictionary *)NSMapGet(kvo_stack, (const void *)self);
	if (!kvoDict) {
		kvoDict = [[NSMutableDictionary alloc] initWithCapacity:0];
		NSMapInsert(kvo_stack, (const void *)self, (const void *)kvoDict);
		[kvoDict release];
	}   
	if (isSet) {
		int setCount = [(NSNumber *)[kvoDict objectForKey:key] intValue] + 1;
		n = [[NSNumber alloc] initWithInt:setCount];
		[kvoDict setValue:n forKey:key];
		[n release];
		if (setCount != 1) {
			return NO;
		}
	} else {
		int setCount = [(NSNumber *)[kvoDict objectForKey:key] intValue] - 1;
		if (setCount != 0) {
			n = [[NSNumber alloc] initWithInt:setCount];
			[kvoDict setValue:n forKey:key];
			[n release];
			return NO;
		} else {
			[kvoDict removeObjectForKey:key];
			if (![kvoDict count]) {
				NSMapRemove(kvo_stack, (const void *)self);
			}
		}
	}
	return YES;
}

#endif

/* Special methods for Python subclasses of Objective-C objects */
static void object_method_dealloc(
		ffi_cif* cif,
		void* retval,
		void** args,
		void* userarg);
static void object_method_respondsToSelector(
		ffi_cif* cif,
		void* retval,
		void** args,
		void* userarg);
static void object_method_methodSignatureForSelector(
		ffi_cif* cif,
		void* retval,
		void** args,
		void* userarg);
static void object_method_forwardInvocation(
		ffi_cif* cif,
		void* retval,
		void** args,
		void* userarg);
static void object_method_valueForKey_(
		ffi_cif* cif,
		void* retval,
		void** args,
		void* userarg);
static void object_method_setValue_forKey_(
		ffi_cif* cif,
		void* retval,
		void** args,
		void* userarg);

#if !defined(MAC_OS_X_VERSION_MIN_REQUIRED) || MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4

static void object_method_willOrDidChangeValueForKey_(
		ffi_cif* cif,
		void* retval,
		void** args,
		void* userarg);
#endif

static char copyWithZone_signature[132] = { '\0' };
static void object_method_copyWithZone_(
		ffi_cif* cif __attribute__((__unused__)),
		void* resp,
		void** args,
		void* userdata);

#define IDENT_CHARS "ABCDEFGHIJKLMNOPQSRTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789"

/*
 * Last step of the construction a python subclass of an objective-C class.
 *
 * Set reference to the python half in the objective-C half of the class.
 *
 * Return 0 on success, -1 on failure.
 */
int 
PyObjCClass_FinishClass(Class objc_class)
{
	PyObjC_Assert(objc_class != nil, -1);

	objc_registerClassPair(objc_class); 
	return 0;
}

/*
 * Call this when the python half of the class could not be created. 
 *
 * Due to technical restrictions it is not allowed to unbuild a class that
 * is already registered with the Objective-C runtime.
 */
int 
PyObjCClass_UnbuildClass(Class objc_class)
{
	PyObjC_Assert(objc_class != nil, -1);
	PyObjC_Assert(objc_lookUpClass(class_getName(objc_class)) == nil, -1);

	objc_freeClassPair(objc_class);
	return 0;
}

/*
 * The Python proxy for an object should not contain any state, even if 
 * the class is defined in Python. Therefore transfer all slots to the 
 * Objective-C class and add '__slots__ = ()' to the Python class.
 */
static int 
do_slots(PyObject* super_class, PyObject* clsdict)
{
	PyObject* slot_value;
	PyObject* slots;
	Py_ssize_t len, i;

	slot_value = PyDict_GetItemString(clsdict, "__slots__");
	if (slot_value == NULL) {
		PyObject* v;

		/* Add an __dict__ unless it is already there */
		PyErr_Clear();

		slot_value = PyTuple_New(0);
		if (slot_value == NULL) {
			return 0;
		}

		if (PyDict_SetItemString(clsdict, "__slots__", slot_value) < 0){
			Py_DECREF(slot_value);
			return -1;
		}
		Py_DECREF(slot_value);

		if (PyObjCClass_DictOffset(super_class) != 0) {
			/* We already have an __dict__ */
			return 0;
		}

		v = PyObjCInstanceVariable_New("__dict__");
		if (v == NULL) {
			return -1;
		}
		((PyObjCInstanceVariable*)v)->type = PyObjCUtil_Strdup(@encode(PyObject*));
		((PyObjCInstanceVariable*)v)->isSlot = 1;
		if (PyDict_SetItemString(clsdict, "__dict__", v) < 0) {
			Py_DECREF(v);
			return -1;
		}
		Py_DECREF(v);

		return 0;
	}

	slots = PySequence_Fast(slot_value, "__slots__ must be a sequence");
	if (slots == NULL) {
		return -1;
	}
	
	len = PySequence_Fast_GET_SIZE(slots);
	for (i = 0; i < len; i++) {
		PyObjCInstanceVariable* var;
		slot_value = PySequence_Fast_GET_ITEM(slots, i);

		if (!PyString_Check(slot_value)) {
			PyErr_Format(PyExc_TypeError, 
				"__slots__ entry %" PY_FORMAT_SIZE_T 
				"d is not a string", i);
			Py_DECREF(slots);
			return -1;
		}

		var = (PyObjCInstanceVariable*)PyObjCInstanceVariable_New(
				PyString_AS_STRING(slot_value));
		if (var == NULL) {
			Py_DECREF(slots);
			return -1;
		}
		((PyObjCInstanceVariable*)var)->type = PyObjCUtil_Strdup(@encode(PyObject*));
		((PyObjCInstanceVariable*)var)->isSlot = 1;
	
		if (PyDict_SetItem(clsdict, slot_value, (PyObject*)var) < 0) {
			Py_DECREF(slots);
			Py_DECREF(var);
			return -1;
		}
		Py_DECREF(var);
	}
	Py_DECREF(slots);

	slot_value = PyTuple_New(0);
	if (slot_value == NULL) {
		return 0;
	}
	if (PyDict_SetItemString(clsdict, "__slots__", slot_value) < 0) {
		Py_DECREF(slot_value);
		return -1;
	}
	Py_DECREF(slot_value);
	return 0;
}

/*
 * Built a (pure Objective-C) subclass of base_class that defines our version
 */

static Class
build_intermediate_class(Class base_class, char* name)
{
	Class intermediate_class = nil;
	IMP closure;
	PyObjCMethodSignature* methinfo = NULL;

	if (copyWithZone_signature[0] == '\0') {
		snprintf(copyWithZone_signature,
			sizeof(copyWithZone_signature),
			"@@:%s", @encode(NSZone*));
	}

	intermediate_class = objc_allocateClassPair(
			base_class, strdup(name), 0);
	if (intermediate_class == NULL) {
		PyErr_NoMemory();
		goto error_cleanup;
	}

	if ([base_class instancesRespondToSelector:@selector(copyWithZone:)]) {
		methinfo = PyObjCMethodSignature_FromSignature(
				copyWithZone_signature);
		if (methinfo == NULL) goto error_cleanup; 
		closure = PyObjCFFI_MakeClosure(methinfo, 
				object_method_copyWithZone_, base_class);
		Py_DECREF(methinfo); methinfo = NULL;
		if (closure == NULL) goto error_cleanup;

		preclass_addMethod(
			intermediate_class,
			@selector(copyWithZone:),
			(IMP)closure,
			copyWithZone_signature);
	}

	methinfo = PyObjCMethodSignature_FromSignature("v@:");
	if (methinfo == NULL) goto error_cleanup; 
	closure = PyObjCFFI_MakeClosure(methinfo, object_method_dealloc,
		base_class);
	Py_DECREF(methinfo); methinfo = NULL;
	if (closure == NULL) goto error_cleanup;

	preclass_addMethod( intermediate_class, @selector(dealloc),
			(IMP)closure, "v@:");

	methinfo = PyObjCMethodSignature_FromSignature("@@:@");
	if (methinfo == NULL) goto error_cleanup; 
	closure = PyObjCFFI_MakeClosure(methinfo, object_method_valueForKey_,
		base_class);
	Py_DECREF(methinfo); methinfo = NULL;
	if (closure == NULL) goto error_cleanup;

	preclass_addMethod(intermediate_class, @selector(valueForKey:),
		(IMP)closure, "@@:@");
	preclass_addMethod(intermediate_class, @selector(storedValueForKey:),
		(IMP)closure, "@@:@");

	methinfo = PyObjCMethodSignature_FromSignature("v@:@@");
	if (methinfo == NULL) goto error_cleanup; 
	closure = PyObjCFFI_MakeClosure(methinfo, object_method_setValue_forKey_,
		base_class);
	Py_DECREF(methinfo); methinfo = NULL;
	if (closure == NULL) goto error_cleanup;
	preclass_addMethod(intermediate_class, @selector(setValue:forKey:),
		(IMP)closure, "v@:@@");
	preclass_addMethod(intermediate_class, 
		@selector(takeStoredValue:forKey:), (IMP)closure, "v@:@@");
	preclass_addMethod(intermediate_class, 
		@selector(takeValue:forKey:), (IMP)closure, "v@:@@");


	methinfo = PyObjCMethodSignature_FromSignature("c@::");
	if (methinfo == NULL) goto error_cleanup; 
	closure = PyObjCFFI_MakeClosure(methinfo, 
		object_method_respondsToSelector,
		base_class);
	Py_DECREF(methinfo); methinfo = NULL;
	if (closure == NULL) goto error_cleanup;
	preclass_addMethod(intermediate_class,
		@selector(respondsToSelector:), 
		(IMP)closure, "c@::");

	methinfo = PyObjCMethodSignature_FromSignature("@@::");
	if (methinfo == NULL) goto error_cleanup; 
	closure = PyObjCFFI_MakeClosure(methinfo, 
		object_method_methodSignatureForSelector,
		base_class);
	Py_DECREF(methinfo); methinfo = NULL;
	if (closure == NULL) goto error_cleanup;
	preclass_addMethod(intermediate_class,
		@selector(methodSignatureForSelector:), 
		(IMP)closure, "@@::");

	methinfo = PyObjCMethodSignature_FromSignature("v@:@");
	if (methinfo == NULL) goto error_cleanup; 
	closure = PyObjCFFI_MakeClosure(methinfo, 
		object_method_forwardInvocation,
		base_class);
	Py_DECREF(methinfo); methinfo = NULL;
	if (closure == NULL) goto error_cleanup;
	preclass_addMethod(intermediate_class,
		@selector(forwardInvocation:), 
		(IMP)closure, "v@:@");

	

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
	if (_KVOHackLevel() == BROKEN_KVO) {
		methinfo = PyObjCMethodSignature_FromSignature("v@:@");
		if (methinfo == NULL) goto error_cleanup; 
		closure = PyObjCFFI_MakeClosure(methinfo, object_method_willOrDidChangeValueForKey_,
			base_class);
		Py_DECREF(methinfo); methinfo = NULL;
		if (closure == NULL) goto error_cleanup;
		preclass_addMethod(intermediate_class, 
			@selector(willChangeValueForKey:), 
			(IMP)closure, "v@:@");
		preclass_addMethod(intermediate_class, 
			@selector(didChangeValueForKey:), 
			(IMP)closure, "v@:@");
	}
#endif

	objc_registerClassPair(intermediate_class);

	return (Class)intermediate_class;

error_cleanup:
	if (intermediate_class) {
		objc_freeClassPair(intermediate_class);
	}
	if (methinfo) {
		Py_DECREF(methinfo);
	}

	return NULL;
}



/*
 * First step of creating a python subclass of an objective-C class
 *
 * Returns NULL or the newly created objective-C class. 'class_dict' may
 * be modified by this function.
 *
 * TODO:
 * - Set 'sel_class' of PyObjCPythonSelector instances
 * - This function complete ignores other base-classes, even though they
 *   might override methods. Need to check the MRO documentation to check
 *   if this is a problem. 
 * - It is a problem when the user tries to use mixins to define common
 *   methods (like a NSTableViewDataSource mixin), this works but slowly
 *   because this calls will always be resolved through forwardInvocation:
 * - Add an 'override' flag that makes it possible to replace an existing
 *   PyObjC class, feature request for the Python-IDE  (write class, run,
 *   oops this doesn't work, rewrite class, reload and continue testing in
 *   the running app)
 */
Class 
PyObjCClass_BuildClass(Class super_class,  PyObject* protocols,
		char* name, PyObject* class_dict, PyObject* meta_dict)
{
	PyObject*                key_list = NULL;
	PyObject*                key = NULL;
	PyObject*                value = NULL;
	Py_ssize_t		 i;
	Py_ssize_t		 key_count;
	Py_ssize_t               protocol_count = 0;
	int                      first_python_gen = 0;
	Class		 	 new_class = NULL;
	Class		 	 new_meta_class = NULL;
	Class                    cur_class;
	PyObject*                py_superclass = NULL;
	Py_ssize_t               item_size;
	int			 have_intermediate = 0;
	int			 need_intermediate = 0;

	if (!PyList_Check(protocols)) {
		PyErr_Format(PyObjCExc_InternalError,  
			"protocol list not a python 'list' but '%s'",
			protocols->ob_type->tp_name);
		goto error_cleanup;
	}
	if (!PyDict_Check(class_dict)) {
		PyErr_Format(PyObjCExc_InternalError, 
			"class dict not a python 'dict', but '%s'",
			class_dict->ob_type->tp_name);
		goto error_cleanup;
	}
	if (super_class == NULL) {
		PyErr_SetString(PyObjCExc_InternalError, 
			"must have super_class");
		goto error_cleanup;
	}

	if ((cur_class = objc_lookUpClass(name)) != NULL) {
		/*
		 * Only allow redefinition of classes that are defined in
		 * python and are in the same module.
		 * This allows using reload() without hiding erroneous
		 * redefinition (e.g. someone forgetting that classnames
		 * must be globally unique).
		 *
		 * XXX: and how does this work? I don't think we actually 
		 * rebuild the class!
		 */

		PyObject* tmp = PyObjCClass_New(cur_class);
		PyObject* m1;
		PyObject* m2;

		if (!PyObjCClass_HasPythonImplementation(tmp)) {
			PyErr_Format(PyObjCExc_Error, 
				"%s is overriding existing Objective-C class", 
				name);
			goto error_cleanup;
		} 

		m1 = PyObject_GetAttrString(tmp, "__module__");
		if (m1 == NULL) {
			PyErr_Clear();
		}

		m2 = PyDict_GetItemString(class_dict, "__module__");
		if (m2 == NULL) {
			PyErr_Clear();
		}

		if (m1 == NULL || m2 == NULL || 
				PyObject_RichCompareBool(m1, m2, Py_EQ) != 1) {
			Py_XDECREF(m1);
			Py_XDECREF(m2);
			if (PyErr_Occurred()) {
				goto error_cleanup;
			}
			PyErr_Format(PyObjCExc_Error, 
				"%s is overriding existing Objective-C class", 
				name);
			goto error_cleanup;
		}
		Py_DECREF(m1);
		Py_DECREF(m2);
		Py_DECREF(tmp);
	}
	if (strspn(name, IDENT_CHARS) != strlen(name)) {
		PyErr_Format(PyObjCExc_Error, "'%s' not a valid name", name);
		goto error_cleanup;
	}

	PyDict_SetItemString(class_dict, "__objc_python_subclass__", Py_True);

	py_superclass = PyObjCClass_New(super_class);
	if (py_superclass == NULL) return NULL;

	/* We must override copyWithZone: for python classes because the
	 * refcounts of python slots might be off otherwise. Yet it should
	 * be possible to override copyWithZone: in those classes. 
	 *
	 * The solution: introduce an intermediate class that contains our
	 * implementation of copyWithZone:. This intermediate class is only
	 * needed when (1) the superclass implements copyWithZone: and (2)
	 * the python subclass overrides that method.
	 *
	 * The same issue is present with a number of other methods.
	 */

	need_intermediate = 0;

	if (PyDict_GetItemString(class_dict, "copyWithZone_") == NULL) {
		PyErr_Clear();
	} else {
		if ([super_class instancesRespondToSelector:@selector(copyWithZone:)]) {
			need_intermediate = 1;
		}
	}

	if (PyDict_GetItemString(class_dict, "dealloc") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}
	if (PyDict_GetItemString(class_dict, "valueForKey_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}
	if (PyDict_GetItemString(class_dict, "storedValueForKey_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}
	if (PyDict_GetItemString(class_dict, "setValueForKey_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}
	if (PyDict_GetItemString(class_dict, "takeValueForKey_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}
	if (PyDict_GetItemString(class_dict, "takeStoredValueForKey_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}
	if (PyDict_GetItemString(class_dict, "respondsToSelector_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}
	if (PyDict_GetItemString(class_dict, "instancesRespondToSelector_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}

	if (PyDict_GetItemString(class_dict, "methodSignatureForSelector_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}
	if (PyDict_GetItemString(class_dict, "forwardInvocation_") == NULL) {
		PyErr_Clear();
	} else {
		need_intermediate = 1;
	}

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
	if (_KVOHackLevel() == BROKEN_KVO) {
		if (PyDict_GetItemString(class_dict, "willChangeValueForKey_") == NULL) {
			PyErr_Clear();
		} else {
			need_intermediate = 1;
		}
		if (PyDict_GetItemString(class_dict, "didChangeValueForKey_") == NULL) {
			PyErr_Clear();
		} else {
			need_intermediate = 1;
		}
	}
#endif

	if (!PyObjCClass_HasPythonImplementation(py_superclass) && need_intermediate) {
		Class intermediate_class;
		char  buf[1024];

		have_intermediate = 1;

		snprintf(buf, 1024, "_PyObjCCopying_%s", class_getName(super_class));
		intermediate_class = objc_lookUpClass(buf);
		if (intermediate_class == NULL) {
			intermediate_class = build_intermediate_class(
					super_class, buf);
			if (intermediate_class == NULL) goto error_cleanup;
		}
		Py_DECREF(py_superclass);

		super_class = intermediate_class;
		py_superclass = PyObjCClass_New(super_class);
		if (py_superclass == NULL) return NULL;
	}


	if (do_slots(py_superclass, class_dict) < 0) {
		goto error_cleanup;
	}


	
	if (!PyObjCClass_HasPythonImplementation(py_superclass)) {
		/* 
		 * This class has a super_class that is pure objective-C
		 * We'll add some instance variables and methods that are
		 * needed for the correct functioning of the class. 
		 *
		 * See the code below the next loop.
		 */
		first_python_gen = 1;
	}


	key_list = PyDict_Keys(class_dict);
	if (key_list == NULL) {
		goto error_cleanup;
	}

	key_count = PyList_Size(key_list);
	if (PyErr_Occurred()) {
		Py_DECREF(key_list);
		goto error_cleanup;
	}

	/* Allocate the class as soon as possible, for new selector objects */
	new_class = objc_allocateClassPair(super_class, name, 0);
	if (new_class == 0) {
		goto error_cleanup;
	}
	
	new_meta_class = object_getClass(new_class);

	/* 0th round: protocols */
	protocol_count = PyList_Size(protocols);
	if (protocol_count > 0) {
		for (i=0; i < protocol_count; i++) {
			PyObject *wrapped_protocol;
			wrapped_protocol = PyList_GET_ITEM(protocols, i);
			if (!PyObjCFormalProtocol_Check(wrapped_protocol)) {
				continue;
			}

			if (!preclass_addProtocol(new_class, 
					PyObjCFormalProtocol_GetProtocol(wrapped_protocol))) {
				goto error_cleanup;
			}
		}
	}

	/* First round, count new instance-vars and check for overridden 
	 * methods.
	 */
	for (i = 0; i < key_count; i++) {
		key = PyList_GET_ITEM(key_list, i);
		if (PyErr_Occurred()) {
			PyErr_SetString(PyObjCExc_InternalError,
				"PyObjCClass_BuildClass: "
				"Cannot fetch key in keylist");
			goto error_cleanup;
		}

		value = PyDict_GetItem(class_dict, key);
		if (value == NULL) {
			PyErr_SetString(PyObjCExc_InternalError,
				"PyObjCClass_BuildClass: "
				"Cannot fetch item in keylist");
			goto error_cleanup;
		}

		if (PyObjCInstanceVariable_Check(value)) {
			if (PyObjCInstanceVariable_SetName(value, key) == -1) {
				goto error_cleanup;
			}
			if (class_getInstanceVariable(super_class, 
			    ((PyObjCInstanceVariable*)value)->name) != NULL) {
				PyErr_Format(PyObjCExc_Error,
					"a superclass already has an instance "
					"variable with this name: %s",
					((PyObjCInstanceVariable*)value)->name);
				goto error_cleanup;
			}

			if (((PyObjCInstanceVariable*)value)->isSlot) {
				item_size = sizeof(PyObject**);
			} else {
				item_size = PyObjCRT_SizeOfType(
					((PyObjCInstanceVariable*)value)->type);
			}
			if (item_size == -1) goto error_cleanup;


		} else if (PyObjCNativeSelector_Check(value)) {
			char methType = '-';
			if (PyObjCSelector_IsClassMethod(value)) {
				methType = '+';
			}
			PyErr_Format(PyExc_TypeError,
				"native selector %c%s of %s",
				methType, 
				sel_getName(PyObjCSelector_GetSelector(value)),
				class_getName(PyObjCSelector_GetClass(value)));
			goto error_cleanup;

		} else if (PyObjCSelector_Check(value)) {
			PyObjCSelector* sel = (PyObjCSelector*)value;

			/* If it already has a sel_class, create a copy */
#if 0
			if (sel->sel_class != NULL) {
				value = PyObjCSelector_Copy(value);
				if (value == NULL) goto error_cleanup;
				if (PyDict_SetItem(class_dict, key, value) == -1) {
					Py_DECREF(value);
					goto error_cleanup;
				}
				Py_DECREF(value);
				sel = (PyObjCSelector*)value;
			}
#endif

			/* Set sel_class */
			sel->sel_class = new_class;

		} else if (
				PyMethod_Check(value) 
			     || PyFunction_Check(value) 
			     || PyObject_TypeCheck(value, &PyClassMethod_Type)){

			PyObject* pyname;
			char*     ocname;
			pyname = key;
			if (pyname == NULL) continue;

			ocname = PyString_AS_STRING(pyname);
			
			if (ocname[0] == '_' && ocname[1] == '_') {
				/* Skip special methods (like __getattr__) to
				 * avoid confusing type().
				 */
				continue;
			}

			value = PyObjCSelector_FromFunction(
					pyname,
					value,
					py_superclass,
					protocols);
			if (value == NULL) goto error_cleanup;

			if (!PyObjCSelector_Check(value)) {
				Py_DECREF(value);
				continue;
			}

			((PyObjCSelector*)value)->sel_class = new_class;

			if (PyDict_SetItem(class_dict, key, value) < 0) {
				Py_DECREF(value); value = NULL;
				goto error_cleanup;
			}
			Py_DECREF(value); value = NULL;
		}
	}

	/* Allocate space for the new instance variables and methods */
	if (first_python_gen) {
		/* Our parent is a pure Objective-C class, add our magic
		 * methods and variables 
		 */
		 
		PyObject* sel;
		IMP closure;
		PyObjCMethodSignature* methinfo;

#		define METH(pyname, selector, types, imp) 		\
		        methinfo = PyObjCMethodSignature_FromSignature(types); \
			if (methinfo == NULL) goto error_cleanup; \
			closure = PyObjCFFI_MakeClosure(methinfo, imp, \
					super_class); \
			Py_DECREF(methinfo); methinfo = NULL; \
			if (closure == NULL) goto error_cleanup; \
			preclass_addMethod(new_class, selector, \
					closure, types); \
			sel = PyObjCSelector_NewNative(new_class, \
				selector,  types, 0);			\
			if (sel == NULL) goto error_cleanup;		\
			PyDict_SetItemString(class_dict, pyname, sel);	\
			Py_DECREF(sel)

		if (!have_intermediate) {
			METH(
				"dealloc", 
				@selector(dealloc), 
				"v@:", 
				object_method_dealloc);
			METH(
				"storedValueForKey_",
				@selector(storedValueForKey:),
				"@@:@",
				object_method_valueForKey_);
			METH(
				"valueForKey_",
				@selector(valueForKey:),
				"@@:@",
				object_method_valueForKey_);
			METH(
				"takeStoredValue_forKey_",
				@selector(takeStoredValue:forKey:),
				"v@:@@",
				object_method_setValue_forKey_);
			METH(
				"takeValue_forKey_",
				@selector(takeValue:forKey:),
				"v@:@@",
				object_method_setValue_forKey_);
			METH(
				"setValue_forKey_",
				@selector(setValue:forKey:),
				"v@:@@",
				object_method_setValue_forKey_);

			METH(
				"forwardInvocation_",
				@selector(forwardInvocation:),
				"v@:@",
				object_method_forwardInvocation);
			METH(
				"methodSignatureForSelector_",
				@selector(methodSignatureForSelector:),
				"@@::",
				object_method_methodSignatureForSelector);
			METH(
				"respondsToSelector",
				@selector(respondsToSelector:),
				"c@::",
				object_method_respondsToSelector);

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
			if (_KVOHackLevel() == BROKEN_KVO) {
				METH(
					"willChangeValueForKey_",
					@selector(willChangeValueForKey:),
					"v@:@",
					object_method_willOrDidChangeValueForKey_);
				METH(
					"didChangeValueForKey_",
					@selector(didChangeValueForKey:),
					"v@:@",
					object_method_willOrDidChangeValueForKey_);
			}
#endif
		}


		if (!have_intermediate && [super_class instancesRespondToSelector:@selector(copyWithZone:)]) {
			if (copyWithZone_signature[0] == '\0') {
				snprintf(copyWithZone_signature,
					sizeof(copyWithZone_signature),
					"@@:%s", @encode(NSZone*));
			}

			METH(
				"copyWithZone_",
				@selector(copyWithZone:),
				copyWithZone_signature,
				object_method_copyWithZone_);
		}
#undef		METH
	}

	for (i = 0; i < key_count; i++) {
		key = PyList_GetItem(key_list, i);
		if (key == NULL) {
			PyErr_SetString(PyObjCExc_InternalError,
				"PyObjCClass_BuildClass: "
				"Cannot fetch key in keylist");
			goto error_cleanup;
		}

		value = PyDict_GetItem(class_dict, key);
		if (value == NULL)  {
			PyErr_SetString(PyObjCExc_InternalError,
				"PyObjCClass_BuildClass: "
				"Cannot fetch item in keylist");
			goto error_cleanup;
		}

		if (PyObjCInstanceVariable_Check(value)) {
			char* type;
			size_t size;
			size_t align;


			if (PyObjCInstanceVariable_IsSlot(value)) {
				type = @encode(PyObject*);
				size = sizeof(PyObject*);
			} else {
				type = PyObjCInstanceVariable_GetType(value);
				size = PyObjCRT_SizeOfType(type);
			}
			align = PyObjCRT_AlignOfType(type);

			if (!preclass_addIvar(new_class, 
				PyObjCInstanceVariable_GetName(value),
				size,
				align,
				type
				)) {

				goto error_cleanup;
			}

		} else if (PyObjCSelector_Check(value)) {
			PyObjCSelector* sel = (PyObjCSelector*)value;
			Method	      meth;
			int           is_override = 0;
			Class	      cls;
			IMP	      imp;
			
			/* Check if the 'key' is the name as the python 
			 * representation of our selector. If not: add the
			 * python representation of our selector to the 
			 * dict as well to ensure that the ObjC interface works
			 * from Python as well.
			 *
			 * NOTE: This also allows one to add both a class
			 * and instance method for the same selector in one
			 * generation.
			 */
			char buf[1024];
			PyObject* pyname = PyString_FromString(
				PyObjC_SELToPythonName(sel->sel_selector, buf, sizeof(buf)));
			if (pyname == NULL) goto error_cleanup;
			int shouldCopy = PyObject_RichCompareBool(pyname, key, Py_EQ);
			if (shouldCopy == -1) goto error_cleanup;


			if (sel->sel_flags & PyObjCSelector_kCLASS_METHOD) {
				meth = class_getClassMethod(super_class,
					sel->sel_selector);
				if (meth) is_override = 1;
				cls = new_meta_class;

				/* Class method: the value should be in the
				 * metadict instead of the regular dict. 
				 * Make it so.
				 */
				if (shouldCopy) {
					if (PyDict_SetItem(meta_dict, pyname, value) == -1) {
						Py_DECREF(pyname);
						goto error_cleanup;
					}
				}
				Py_DECREF(pyname);

				if (PyDict_SetItem(meta_dict, key, value) == -1)
					goto error_cleanup;
				if (PyDict_DelItem(class_dict, key) == -1)
					goto error_cleanup;



			} else {
				meth = class_getInstanceMethod(super_class,
					sel->sel_selector);
				if (meth) is_override = 1;
				cls = new_class;

				if (shouldCopy) {
					if (PyDict_SetItem(class_dict, pyname, value) == -1) {
						Py_DECREF(pyname);
						goto error_cleanup;
					}
				}
				Py_DECREF(pyname);
			}
		
			if (is_override) {
				imp = PyObjC_MakeIMP(cls, super_class, value, value);
			} else  {
				imp = PyObjC_MakeIMP(cls, nil, value, value);
			}
			if (imp == NULL) {
				goto error_cleanup;
			}

			if (!preclass_addMethod(cls, sel->sel_selector, imp,
						sel->sel_python_signature)) {
				goto error_cleanup;
			}

			if (sel->sel_class == NULL) {
				sel->sel_class = new_class;
			}
		} /* XXX: else if (PyObjCIMP_Check(value)) { */
	}
	Py_DECREF(key_list);
	key_list = NULL;

	Py_XDECREF(py_superclass); py_superclass = NULL;

	if (PyDict_DelItemString(class_dict, "__dict__") < 0) {
		PyErr_Clear();
	}

	/* 
	 * NOTE: Class is not registered yet, we do that as lately as possible
	 * because it is impossible to remove the registration from the
	 * objective-C runtime (at least on MacOS X).
	 */
	return new_class;

error_cleanup:
	Py_XDECREF(py_superclass);

	if (key_list) {
		Py_DECREF(key_list);
		key_list = NULL;
	}

	if (new_class) {
		objc_freeClassPair(new_class);
	}

	return NULL;
}

/*
 * Below here are implementations of various methods needed to correctly
 * subclass Objective-C classes from Python. 
 *
 * These are added to the new Objective-C class by  PyObjCClass_BuildClass (but
 * only if the super_class is a 'pure' objective-C class)
 *
 * NOTE:
 * - These functions will be used as methods, but as far as the compiler
 *   knows these are normal functions. You cannot use [super call]s here.
 */


static void
free_ivars(id self, PyObject* volatile cls )
{
	/* Free all instance variables introduced through python */
	volatile Ivar var;

	var = class_getInstanceVariable(PyObjCClass_GetClass(cls), "__dict__");
	if (var != NULL) {
		ptrdiff_t offset = ivar_getOffset(var);
		Py_XDECREF(*(PyObject**)(((char*)self) + offset));
		*(PyObject**)(((char*)self) + offset) = NULL;
	}

	while (cls != NULL) {
		Class objcClass = PyObjCClass_GetClass(cls);
		PyObject* clsDict; 
		PyObject* clsValues;
		PyObject* o;
		volatile Py_ssize_t i;
		Py_ssize_t len;

		if (objcClass == nil) break;


		clsDict = PyObject_GetAttrString(cls, "__dict__");
		if (clsDict == NULL) {
			PyErr_Clear();
			break;
		}
		
		/* Class.__dict__ is a dictproxy, which is not a dict and
		 * therefore PyDict_Values doesn't work.
		 */
		clsValues = PyObject_CallMethod(clsDict, "values", NULL);
		Py_DECREF(clsDict);
		if (clsValues == NULL) {
			PyErr_Clear();
			break;
		}

		len = PyList_Size(clsValues);
		/* Check type */
		for (i = 0; i < len; i++) {
			PyObjCInstanceVariable* iv;

			o = PyList_GET_ITEM(clsValues, i);

			if (o == NULL) continue;
			if (!PyObjCInstanceVariable_Check(o)) continue;
		
			iv = ((PyObjCInstanceVariable*)o);

			if (iv->isOutlet) continue;
			if (strcmp(iv->type, "@") != 0 && strcmp(iv->type, @encode(PyObject*)) != 0) continue;

			var = class_getInstanceVariable(objcClass, iv->name);
			if (var == NULL) continue;

			if (iv->isSlot) {
				Py_XDECREF(*(PyObject**)(((char*)self) + 
					ivar_getOffset(var)));
				(*(PyObject**)(((char*)self) + 
					ivar_getOffset(var))) = NULL;
			} else {
				PyObjC_DURING
					[*(id*)(((char*)self) + ivar_getOffset(var)) autorelease];

				PyObjC_HANDLER
					NSLog(@"ignoring exception %@ in destructor",
						localException);

				PyObjC_ENDHANDLER
				*(id*)(((char*)self) + ivar_getOffset(var)) = NULL;
			}
		}

		Py_DECREF(clsValues);

		o = PyObject_GetAttrString(cls, "__bases__");
		if (o == NULL) {
			PyErr_Clear();
			cls = NULL;
		}  else if (PyTuple_Size(o) == 0) {
			PyErr_Clear();
			cls = NULL;
			Py_DECREF(o);
		} else {
			cls = PyTuple_GET_ITEM(o, 0);
			if (cls == (PyObject*)&PyObjCClass_Type) {
				cls = NULL;
			}
			Py_DECREF(o);
		}
	}
}

/* -dealloc */
static void 
object_method_dealloc(
		ffi_cif* cif __attribute__((__unused__)),
		void* retval __attribute__((__unused__)),
		void** args,
		void* userdata)
{
	id self = *(id*)(args[0]);
	SEL _meth = *(SEL*)(args[1]);

	struct objc_super spr;
	PyObject* obj;
	PyObject* delmethod;
	PyObject* cls;
	PyObject* ptype, *pvalue, *ptraceback;

	PyObjC_BEGIN_WITH_GIL

		PyErr_Fetch(&ptype, &pvalue, &ptraceback);

		cls = PyObjCClass_New(object_getClass(self));

		delmethod = PyObjCClass_GetDelMethod(cls);
		if (delmethod != NULL) {
			PyObject* s = _PyObjCObject_NewDeallocHelper(self);
			obj = PyObject_CallFunction(delmethod, "O", s);
			_PyObjCObject_FreeDeallocHelper(s);
			if (obj == NULL) {
				PyErr_WriteUnraisable(delmethod);
			} else {
				Py_DECREF(obj);
			}
			Py_DECREF(delmethod);
		}

		free_ivars(self, cls);

		PyErr_Restore(ptype, pvalue, ptraceback);

	PyObjC_END_WITH_GIL

	objc_superSetClass(spr, (Class)userdata);
	objc_superSetReceiver(spr, self);

	objc_msgSendSuper(&spr, _meth);
}

/* -copyWithZone:(NSZone*)zone */
static void
object_method_copyWithZone_(
		ffi_cif* cif __attribute__((__unused__)),
		void* resp,
		void** args,
		void* userdata)
{
	id self = *(id*)args[0];
	id copy;
	SEL _meth = *(SEL*)args[1];
	NSZone* zone = *(NSZone**)args[2];
	Class cls;

	struct objc_super spr;
	PyGILState_STATE state;

	/* Ask super to create a copy */

	objc_superSetClass(spr, (Class)userdata);
	objc_superSetReceiver(spr, self);
	copy = objc_msgSendSuper(&spr, _meth, zone);

	if (copy == nil) {
		*(id*)resp = nil;
		return;
	}

	state = PyGILState_Ensure();

	cls = object_getClass(self);
	while (cls != (Class)userdata) {
		unsigned ivarCount, i;
		Ivar* ivarList = class_copyIvarList(cls, &ivarCount);

		for (i = 0; i < ivarCount; i++) {
			Ivar v = ivarList[i];
			const char*  typestr;
			ptrdiff_t offset;
			PyObject** p;

			typestr = ivar_getTypeEncoding(v);
			offset  = ivar_getOffset(v);

			if (strcmp(typestr, @encode(PyObject*))!=0)
				continue;

			/* A PyObject, increase it's refcount */
			p = (PyObject**)(((char*)copy)+offset);
			if (*p == NULL) continue;
			if (strcmp(ivar_getName(v), "__dict__") == 0) {
				/* copy __dict__ */
				*p = PyDict_Copy(*p);
				if (*p == NULL) {
					[copy release];
					PyObjCErr_ToObjCWithGILState(
							&state);
					return;
				}
			} else {
				Py_INCREF(*p);
			}
		}

		free(ivarList);
		cls = class_getSuperclass(cls);
	}

	PyGILState_Release(state);
	*(id*)resp = copy;
}

/* -respondsToSelector: */
static void 
object_method_respondsToSelector(
		ffi_cif* cif __attribute__((__unused__)),
		void* retval,
		void** args,
		void* userdata)
{
	id self = *(id*)args[0];
	SEL _meth = *(SEL*)args[1];
	SEL aSelector = *(SEL*)args[2];
	int* pres = (int*)retval; // Actually BOOL.

	struct objc_super spr;
	PyObject* pyself;
	PyObject* pymeth;

	PyObjC_BEGIN_WITH_GIL
		/* First check if we respond */
		pyself = PyObjCObject_New(self, PyObjCObject_kDEFAULT, YES);
		if (pyself == NULL) {
			*pres = NO;
			PyObjC_GIL_RETURNVOID;
		}
		pymeth = PyObjCObject_FindSelector(pyself, aSelector);
		Py_DECREF(pyself);
		if (pymeth) {
			*pres = YES;

			if (PyObjCSelector_Check(pymeth) && (((PyObjCSelector*)pymeth)->sel_flags & PyObjCSelector_kCLASS_METHOD)) {
				*pres = NO;	
			}
			
			Py_DECREF(pymeth);
			PyObjC_GIL_RETURNVOID;
		}
		PyErr_Clear();
	
	PyObjC_END_WITH_GIL

	/* Check superclass */
	objc_superSetClass(spr, (Class)userdata);
	objc_superSetReceiver(spr, self);

	*pres = ((int(*)(struct objc_super*, SEL, SEL))objc_msgSendSuper)(&spr, _meth, aSelector);
	return;
}

/* -methodSignatureForSelector */
static void
object_method_methodSignatureForSelector(
		ffi_cif* cif __attribute__((__unused__)),
		void* retval,
		void** args,
		void* userdata)
{
	id self = *(id*)args[0];
	SEL _meth = *(SEL*)args[1];
	SEL aSelector = *(SEL*)args[2];

	struct objc_super  spr;
	PyObject*          pyself;
	PyObject*          pymeth;
	NSMethodSignature** presult = (NSMethodSignature**)retval;

	*presult = nil;

	objc_superSetClass(spr, (Class)userdata);
	objc_superSetReceiver(spr, self);

	NS_DURING
		*presult = objc_msgSendSuper(&spr, _meth, aSelector);
	NS_HANDLER
		*presult = nil;
	NS_ENDHANDLER

	if (*presult != nil) {
		return;
	}

	PyObjC_BEGIN_WITH_GIL
		pyself = PyObjCObject_New(self, PyObjCObject_kDEFAULT, YES);
		if (pyself == NULL) {
			PyErr_Clear();
			PyObjC_GIL_RETURNVOID;
		}

		pymeth = PyObjCObject_FindSelector(pyself, aSelector);
		if (!pymeth) {
			Py_DECREF(pyself);
			PyErr_Clear();
			PyObjC_GIL_RETURNVOID;
		}
	
	PyObjC_END_WITH_GIL

	NS_DURING
		*presult =  [NSMethodSignature signatureWithObjCTypes:(
				(PyObjCSelector*)pymeth)->sel_python_signature];
	NS_HANDLER
		PyObjC_BEGIN_WITH_GIL
			Py_DECREF(pymeth);
			Py_DECREF(pyself);

		PyObjC_END_WITH_GIL
		[localException raise];
	NS_ENDHANDLER

	PyObjC_BEGIN_WITH_GIL
		Py_DECREF(pymeth);
		Py_DECREF(pyself);

	PyObjC_END_WITH_GIL

}

/* -forwardInvocation: */
static void
object_method_forwardInvocation(
		ffi_cif* cif __attribute__((__unused__)),
		void* retval __attribute__((__unused__)),
		void** args,
		void* userdata)
{
	id self = *(id*)args[0];
	SEL _meth = *(SEL*)args[1];
	NSInvocation* invocation = *(NSInvocation**)args[2];
	SEL theSelector;

	PyObject*	arglist;
	PyObject* 	result;
	PyObject*       v;
	BOOL		isAlloc;
	BOOL		isCFAlloc;
	Py_ssize_t      i;
	Py_ssize_t	len;
	PyObjCMethodSignature* signature;
	/*char		   argbuf[1024]; */
	const char* 		type;
	void* argbuf = NULL;
	int  err;
	Py_ssize_t   arglen;
	PyObject* pymeth;
	PyObject* pyself;
	volatile int have_output = 0;
	PyGILState_STATE state = PyGILState_Ensure();

	pyself = PyObjCObject_New(self, PyObjCObject_kDEFAULT, YES);
	if (pyself == NULL) {
		PyObjCErr_ToObjCWithGILState(&state);
		return;
	}


	PyObjC_DURING
		theSelector = [invocation selector];
	PyObjC_HANDLER
		PyGILState_Release(state);
		[localException raise];

		/* Avoid compiler warnings */
		theSelector = @selector(init);

	PyObjC_ENDHANDLER

	pymeth = PyObjCObject_FindSelector(pyself, theSelector);

	if ((pymeth == NULL) || PyObjCNativeSelector_Check(pymeth)) {
		struct objc_super spr;

		if (pymeth == NULL) {
			PyErr_Clear();
		}

		Py_XDECREF(pymeth);
		Py_XDECREF(pyself);

		objc_superSetClass(spr, (Class)userdata);
		objc_superSetReceiver(spr, self);
		PyGILState_Release(state);
		objc_msgSendSuper(&spr, _meth, invocation);
		return;
	}


	signature = PyObjCMethodSignature_FromSignature(
		PyObjCSelector_Signature(pymeth));
	len = signature->ob_size;

	Py_XDECREF(pymeth); pymeth = NULL;

	arglist = PyList_New(1);
	if (arglist == NULL) {
		Py_DECREF(signature);
		PyObjCErr_ToObjCWithGILState(&state);
		return;
	}

	PyList_SET_ITEM(arglist, 0, pyself);
	pyself = NULL;

	for (i = 2; i < len; i++) {
		type = signature->argtype[i].type;
		if (type == NULL) {
			PyErr_SetString(PyObjCExc_InternalError, "corrupt metadata");
			Py_DECREF(arglist);
			Py_DECREF(signature);
			PyObjCErr_ToObjCWithGILState(&state);
			return;
		}

		arglen = PyObjCRT_SizeOfType(type);

		if (arglen == -1) {
			Py_DECREF(arglist);
			Py_DECREF(signature);
			PyObjCErr_ToObjCWithGILState(&state);
			return;
		}

		argbuf = PyMem_Malloc(arglen+64);
		
		[invocation getArgument:argbuf atIndex:i];

		/* XXX: this needs a lot of work to adapt to the new metadata!!! */

		switch (*type) {
		case _C_INOUT:
			if (type[1] == _C_PTR) {
				have_output ++;
			}
			/* FALL THROUGH */
		case _C_IN: case _C_CONST:
			if (type[1] == _C_PTR) {
				v = pythonify_c_value(type+2, *(void**)argbuf);
			} else {
				v = pythonify_c_value(type+1, argbuf);
			}
			break;
		case _C_OUT:
			if (type[1] == _C_PTR) {
				have_output ++;
			}
			PyMem_Free(argbuf); argbuf = NULL;
			continue;
		default:
			v = pythonify_c_value(type, argbuf);
		}
		PyMem_Free(argbuf); argbuf = NULL;

		if (v == NULL) {
			Py_DECREF(arglist);
			Py_DECREF(signature);
			PyObjCErr_ToObjCWithGILState(&state);
			return;
		}

		if (PyList_Append(arglist, v) < 0) {
			Py_DECREF(arglist);
			Py_DECREF(signature);
			PyObjCErr_ToObjCWithGILState(&state);
			return;
		}
	}

	v = PyList_AsTuple(arglist);
	if (v == NULL) {
		Py_DECREF(arglist);
		Py_DECREF(signature);
		PyObjCErr_ToObjCWithGILState(&state);
		return;
	}
	Py_DECREF(arglist);
	arglist = v; v = NULL;

	result = PyObjC_CallPython(self, theSelector, arglist, &isAlloc, &isCFAlloc);
	Py_DECREF(arglist);
	if (result == NULL) {
		Py_DECREF(signature);
		PyObjCErr_ToObjCWithGILState(&state);
		return;
	}

	type = signature->rettype.type;
	arglen = PyObjCRT_SizeOfType(type);

	if (arglen == -1) {
		Py_DECREF(signature);
		PyObjCErr_ToObjCWithGILState(&state);
		return;
	}

	if (!have_output) {
		if (*type  != _C_VOID && *type != _C_ONEWAY) {
			argbuf = PyMem_Malloc(arglen+64);

			err = depythonify_c_value(type, result, argbuf);
			if (err == -1) {
				PyMem_Free(argbuf);
				Py_DECREF(signature);
				PyObjCErr_ToObjCWithGILState(&state);
				return;
			}
			if (isAlloc) {
				[(*(id*)argbuf) retain];
			} else if (isCFAlloc) {
				if (*(id*)argbuf != nil) {
					CFRetain((*(id*)argbuf));
				}
			}
			[invocation setReturnValue:argbuf];
			PyMem_Free(argbuf);
		}
		Py_DECREF(result);

	} else {
		Py_ssize_t idx;
		PyObject* real_res;

		if (*type == _C_VOID && have_output == 1) {
			/* One output argument, and a 'void' return value,
			 * the python method returned just the output
			 * argument
			 */
			/* This should be cleaned up, unnecessary code
			 * duplication
			 */

			for (i = 2; i < len;i++) {
				void* ptr;
				type = signature->argtype[i].type;

				if (arglen == -1) {
					Py_DECREF(signature);
					PyObjCErr_ToObjCWithGILState(&state);
					return;
				}

				switch (*type) {
				case _C_INOUT: case _C_OUT:
					if (type[1] != _C_PTR) {
						continue;
					}
					type += 2;
					break;
				default:
					continue;
				}

				[invocation getArgument:&ptr atIndex:i];
				err = depythonify_c_value(type, result, ptr);
				if (err == -1) {
					Py_DECREF(signature);
					PyObjCErr_ToObjCWithGILState(&state);
					return;
				}
				if (result->ob_refcnt == 1 && type[0] == _C_ID) {
					/* make sure return value doesn't die before
					 * the caller can get its hands on it.
					 */
					[[*(id*)ptr retain] autorelease];
				}

				/* We have exactly 1 output argument */
				break;

			}

			Py_DECREF(signature);
			Py_DECREF(result);
			PyGILState_Release(state);
			return;
		}

		if (*type != _C_VOID) {
			if (!PyTuple_Check(result) 
			     || PyTuple_Size(result) != have_output+1) {
				PyErr_Format(PyExc_TypeError,
					"%s: Need tuple of %d arguments as result",
					sel_getName(theSelector),
					have_output+1);
				Py_DECREF(result);
				Py_DECREF(signature);
				PyObjCErr_ToObjCWithGILState(&state);
				return;
			}
			idx = 1;
			real_res = PyTuple_GET_ITEM(result, 0);

			argbuf = PyMem_Malloc(arglen+64);

			err = depythonify_c_value(type, real_res, argbuf);
			if (err == -1) {
				Py_DECREF(signature);
				PyObjCErr_ToObjCWithGILState(&state);
				PyMem_Free(argbuf);
				return;
			}
			if (isAlloc) {
				[(*(id*)argbuf) retain];
			} else if (isCFAlloc) {
				CFRetain(*(id*)argbuf);
			}
			[invocation setReturnValue:argbuf];
			PyMem_Free(argbuf);

		} else {
			if (!PyTuple_Check(result) 
			     || PyTuple_Size(result) != have_output) {
				PyErr_Format(PyExc_TypeError,
					"%s: Need tuple of %d arguments as result",
					sel_getName(theSelector),
					have_output);
				Py_DECREF(signature);
				Py_DECREF(result);
				PyObjCErr_ToObjCWithGILState(&state);
				return;
			}
			idx = 0;
		}


		for (i = 2; i < len;i++) {
			void* ptr;
			type = signature->argtype[i].type;

			if (arglen == -1) {
				Py_DECREF(signature);
				PyObjCErr_ToObjCWithGILState(&state);
				return;
			}

			switch (*type) {
			case _C_INOUT: case _C_OUT:
				if (type[1] != _C_PTR) {
					continue;
				}
				type += 2;
				break;
			default:
				continue;
			}

			[invocation getArgument:&ptr atIndex:i];
			v = PyTuple_GET_ITEM(result, idx++);
			err = depythonify_c_value(type, v, ptr);
			if (err == -1) {
				Py_DECREF(signature);
				PyObjCErr_ToObjCWithGILState(&state);
				return;
			}
			if (v->ob_refcnt == 1 && type[0] == _C_ID) {
				/* make sure return value doesn't die before
				 * the caller can get its hands on it.
			   	 */
				[[*(id*)ptr retain] autorelease];
			}

		}
		Py_DECREF(result);
	}
	Py_DECREF(signature);
	PyGILState_Release(state);
}

/*
 * XXX: Function PyObjC_CallPython should be moved
 */
PyObject*
PyObjC_CallPython(id self, SEL selector, PyObject* arglist, BOOL* isAlloc, BOOL* isCFAlloc)
{
	PyObject* pyself = NULL;
	PyObject* pymeth = NULL;
	PyObject* result;

	pyself = pythonify_c_value(@encode(id), &self);
	if (pyself == NULL) {
		return NULL;
	}
	
	if (PyObjCClass_Check(pyself)) {
		pymeth = PyObjCClass_FindSelector(pyself, selector, YES);
	} else {
		pymeth = PyObjCObject_FindSelector(pyself, selector);
	}
	if (pymeth == NULL) {
		Py_DECREF(pyself);
		return NULL;
	}

	if (NULL != ((PyObjCSelector*)pymeth)->sel_self) {
		/* The selector is a bound selector, we didn't expect that...*/
		PyObject* arg_self;

		arg_self = PyTuple_GET_ITEM(arglist, 0);
		if (arg_self == NULL) {
			return NULL;
		}
		if (arg_self != ((PyObjCSelector*)pymeth)->sel_self) {

			PyErr_SetString(PyExc_TypeError,
				"PyObjC_CallPython called with 'self' and "
				"a method bound to another object");
			return NULL;
		}

		arglist = PyTuple_GetSlice(arglist, 1, PyTuple_Size(arglist));
		if (arglist == NULL) {
			return NULL;
		}
	} else {
		Py_INCREF(arglist);
	}

	if (isAlloc != NULL) {
		*isAlloc = PyObjCSelector_GetMetadata(pymeth)->rettype.alreadyRetained;
	}
	if (isCFAlloc != NULL) {
		*isCFAlloc = PyObjCSelector_GetMetadata(pymeth)->rettype.alreadyCFRetained;
	}

	result = PyObject_Call(pymeth, arglist, NULL);
	Py_DECREF(arglist);
	Py_DECREF(pymeth);
	Py_DECREF(pyself);

	if (result == NULL) {
		return NULL;
	}

	return result;
}

static void
object_method_valueForKey_(
		ffi_cif* cif __attribute__((__unused__)),
		void* retval,
		void** args,
		void* userdata)
{
	// This method does the following:
	//     - Checks super implementation
	//     - if [[self class] accessInstanceVariablesDirectly]
	//         - Checks for attribute key
	//         - Checks for attribute _key
	int r;
	id self = *(id*)args[0];
	SEL _meth = *(SEL*)args[1];
	NSString* key = *(NSString**)args[2];

	struct objc_super spr;

	// First check super
	NS_DURING
		objc_superSetClass(spr, (Class)userdata);
		objc_superSetReceiver(spr, self);
		*((id *)retval) = (id)objc_msgSendSuper(&spr, _meth, key);
	NS_HANDLER
		/* Parent doesn't know the key, try to create in the 
		 * python side, just like for plain python objects.
		 */
		if (([[localException name] isEqual:@"NSUnknownKeyException"]
			) && [[self class] accessInstanceVariablesDirectly]) {

			PyGILState_STATE state = PyGILState_Ensure();
			PyObject* selfObj = PyObjCObject_New(self, PyObjCObject_kDEFAULT, YES);
			PyObject *res = NULL;
			r = -1;
			do {
				res = PyObject_GetAttrString(selfObj, (char *)[key UTF8String]);
				if (res == NULL) {
					PyErr_Clear();
					res = PyObject_GetAttrString(selfObj, (char *)[[@"_" stringByAppendingString:key] UTF8String]);
					if (res == NULL) {
						break;
					}
				}

				/* Check that we don't accidently return 
				 * an accessor method.
				 */
				if (PyObjCSelector_Check(res) &&
					((PyObjCSelector*)res)->sel_self == selfObj) {
					Py_DECREF(res); res = NULL;
					break;
				}
				r = depythonify_c_value(@encode(id), res, retval);
			} while (0);
			Py_DECREF(selfObj);
			Py_XDECREF(res);
			if (r == -1) {
				PyErr_Clear();
				PyGILState_Release(state);
				[localException raise];
			}
			PyGILState_Release(state);
		} else {
			[localException raise];
		}
	NS_ENDHANDLER

}


#if !defined(MAC_OS_X_VERSION_MIN_REQUIRED) || MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4

static void
object_method_willOrDidChangeValueForKey_(
		ffi_cif* cif __attribute__((__unused__)),
		void* retval __attribute__((__unused__)),
		void** args,
		void* userdata) {
	struct objc_super spr;
	id self = *(id*)args[0];
	SEL _meth = *(SEL*)args[1];
	NSString* key = *(NSString**)args[2];

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
	BOOL isSet = (_meth == @selector(willChangeValueForKey:));
	if (_UseKVO(self, key, isSet)) {
		objc_superSetClass(spr, (Class)userdata);
		objc_superSetReceiver(spr, self);
		(void)objc_msgSendSuper(&spr, _meth, key);
	}

#else
	objc_superSetClass(spr, (Class)userdata);
	objc_superSetReceiver(spr, self);
	(void)objc_msgSendSuper(&spr, _meth, key);
#endif

}

#endif

static void
object_method_setValue_forKey_(
		ffi_cif* cif __attribute__((__unused__)),
		void* retval __attribute__((__unused__)),
		void** args,
		void* userdata)
{
	// This method does the following:
	//     - Checks super implementation
	//     - if [[self class] accessInstanceVariablesDirectly]
	//	       - Checks for attribute _key and sets if present
	//		   - Sets attribute key
	int r;
	struct objc_super spr;
	id self = *(id*)args[0];
	SEL _meth = *(SEL*)args[1];
	id value = *(id*)args[2];
	NSString* key = *(NSString**)args[3];

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
	// Set up a KVO stack so you only get one notification from this
	NS_DURING
		if (_KVOHackLevel() == BROKEN_KVO) {
			[self willChangeValueForKey:key];
		}
	NS_HANDLER
	NS_ENDHANDLER
#endif

	NS_DURING
		// First check super
		objc_superSetClass(spr, (Class)userdata);
		objc_superSetReceiver(spr, self);
		(void)objc_msgSendSuper(&spr, _meth, value, key);
	NS_HANDLER
		/* Parent doesn't know the key, try to create in the 
		 * python side, just like for plain python objects.
		 */
		if (([[localException name] isEqual:@"NSUnknownKeyException"]
			) && [[self class] accessInstanceVariablesDirectly]) {

			PyGILState_STATE state = PyGILState_Ensure();
			PyObject* val = pythonify_c_value(@encode(id), &value);
			if (val == NULL) {
				PyErr_Clear();
				PyGILState_Release(state);

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
				// Pop the KVO stack
				if (_KVOHackLevel() == BROKEN_KVO) {
				    [self didChangeValueForKey:key];
				}
#endif

				[localException raise];
			}
			PyObject* res = NULL;
			PyObject* selfObj = PyObjCObject_New(self, PyObjCObject_kDEFAULT, YES);
			r = -1;
			do {
				char *rawkey = (char *)[[@"_" stringByAppendingString:key] UTF8String];
				res = PyObject_GetAttrString(selfObj, rawkey);
				if (res != NULL) {
					r = PyObject_SetAttrString(selfObj, rawkey, val);
					if (r != -1) {
						break;
					}
				}
				PyErr_Clear();
				rawkey = (char *)[key UTF8String];
				r = PyObject_SetAttrString(selfObj, rawkey, val);
			} while (0);
			Py_DECREF(selfObj);
			Py_DECREF(val);
			Py_XDECREF(res);
			if (r == -1) {
				PyErr_Clear();
				PyGILState_Release(state);
#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
				// Pop the KVO stack
				if (_KVOHackLevel() == BROKEN_KVO) {
				    [self didChangeValueForKey:key];
				}
#endif
				[localException raise];
			}
			PyGILState_Release(state);
		} else {
#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
			// Pop the KVO stack
			if (_KVOHackLevel() == BROKEN_KVO) {
				[self didChangeValueForKey:key];
			}
#endif
			[localException raise];
		}
	NS_ENDHANDLER

#if MAC_OS_X_VERSION_MIN_REQUIRED < MAC_OS_X_VERSION_10_4
	// Pop the KVO stack
	if (_KVOHackLevel() == BROKEN_KVO) {
		[self didChangeValueForKey:key];
	}
#endif
}
