;;;; -------------------------------------------------------------------------
;;;; Plan

(asdf/package:define-package :asdf/plan
  (:recycle :asdf/plan :asdf)
  (:use :common-lisp :asdf/utility :asdf/pathname :asdf/os :asdf/upgrade
   :asdf/component :asdf/system :asdf/find-system :asdf/find-component
   :asdf/operation :asdf/action)
  #+gcl<2.7 (:shadowing-import-from :asdf/compatibility #:type-of)
  (:intern #:planned-p #:index #:forced #:forced-not #:total-action-count
           #:planned-action-count #:planned-output-action-count #:visited-actions
           #:visiting-action-set #:visiting-action-list #:actions-r)
  (:export
   #:component-operation-time #:mark-operation-done
   #:plan-traversal #:sequential-plan
   #:planned-action-status #:plan-action-status #:action-already-done-p
   #:circular-dependency #:circular-dependency-actions
   #:node-for #:needed-in-image-p
   #:plan-record-dependency #:visiting-action-p
   #:normalize-forced-systems #:action-forced-p #:action-forced-not-p
   #:visit-dependencies #:compute-action-stamp #:traverse-action
   #:call-while-visiting-action #:while-visiting-action
   #:traverse-sequentially #:traverse
   #:perform-plan #:plan-operates-on-p))
(in-package :asdf/plan)

(when-upgrade () (undefine-functions '(traverse perform-plan traverse-action)))

;;;; Planned action status

(defgeneric* plan-action-status (plan operation component)
  (:documentation "Returns the ACTION-STATUS associated to
the action of OPERATION on COMPONENT in the PLAN"))

(defgeneric* (setf plan-action-status) (new-status plan operation component)
  (:documentation "Sets the ACTION-STATUS associated to
the action of OPERATION on COMPONENT in the PLAN"))

(defclass planned-action-status (action-status)
  ((planned-p
    :initarg :planned-p :reader action-planned-p
    :documentation "a boolean, true iff the action was included in the plan.")
   (index
    :initarg :index :reader action-index
    :documentation "an integer, counting all traversed actions in traversal order."))
  (:documentation "Status of an action in a plan"))

(defmethod print-object ((status planned-action-status) stream)
  (print-unreadable-object (status stream :type t)
    (with-slots (stamp done-p planned-p) status
      (format stream "~@{~S~^ ~}" :stamp stamp :done-p done-p :planned-p planned-p))))

;; TODO: eliminate NODE-FOR, use CONS.
;; Supposes cleaner protocol for operation initargs passed to MAKE-OPERATION.
;; However, see also component-operation-time and mark-operation-done
(defun* node-for (o c) (cons (type-of o) c))

(defun* action-already-done-p (plan operation component)
  (action-done-p (plan-action-status plan operation component)))

(defmethod plan-action-status ((plan null) (o operation) (c component))
  (declare (ignorable plan))
  (multiple-value-bind (stamp done-p) (component-operation-time o c)
    (make-instance 'action-status :stamp stamp :done-p done-p)))

(defmethod (setf plan-action-status) (new-status (plan null) (o operation) (c component))
  (declare (ignorable plan))
  (let ((to (type-of o))
        (times (component-operation-times c)))
    (if (action-done-p new-status)
        (remhash to times)
        (setf (gethash to times) (action-stamp new-status))))
  new-status)


;;;; forcing

(defgeneric* action-forced-p (plan operation component))
(defgeneric* action-forced-not-p (plan operation component))

(defun* normalize-forced-systems (x system)
  (etypecase x
    ((member nil :all) x)
    (cons (list-to-hash-set (mapcar #'coerce-name x)))
    ((eql t) (list-to-hash-set (list (coerce-name system))))))

(defun* action-override-p (plan operation component override-accessor)
  (declare (ignorable operation))
  (let* ((override (funcall override-accessor plan)))
    (and override
         (if (typep override 'hash-table)
             (gethash (coerce-name (component-system (find-component () component))) override)
             t))))

(defmethod action-forced-p (plan operation component)
  (and (action-override-p plan operation component 'plan-forced)
       (not (builtin-system-p (component-system component)))))
(defmethod action-forced-not-p (plan operation component)
  (and (action-override-p plan operation component 'plan-forced-not)
       (not (action-forced-p plan operation component))))


;;;; action-valid-p

(defgeneric action-valid-p (plan operation component)
  (:documentation "Is this action valid to include amongst dependencies?"))
(defmethod action-valid-p (plan operation (c component))
  (declare (ignorable plan operation))
  (aif (component-if-feature c) (featurep it) t))
(defmethod action-valid-p (plan (o null) c) (declare (ignorable plan o c)) nil)
(defmethod action-valid-p (plan o (c null)) (declare (ignorable plan o c)) nil)


;;;; Is the action needed in this image?

(defgeneric* needed-in-image-p (operation component)
  (:documentation "Is the action of OPERATION on COMPONENT needed in the current image to be meaningful,
    or could it just as well have been done in another Lisp image?"))

(defmethod needed-in-image-p ((o operation) (c component))
  ;; We presume that actions that modify the filesystem don't need be run
  ;; in the current image if they have already been done in another,
  ;; and can be run in another process (e.g. a fork),
  ;; whereas those that don't are meant to side-effect the current image and can't.
  (not (output-files o c)))


;;;; Visiting dependencies of an action and computing action stamps

(defun* visit-dependencies (plan operation component fun &aux stamp)
  (loop :for (dep-o-spec . dep-c-specs) :in (component-depends-on operation component)
        :unless (eq dep-o-spec 'feature) ;; avoid the "FEATURE" misfeature
          :do (loop :with dep-o = (find-operation operation dep-o-spec)
                    :for dep-c-spec :in dep-c-specs
                    :for dep-c = (resolve-dependency-spec component dep-c-spec)
                    :when (action-valid-p plan dep-o dep-c)
                      :do (latest-stamp-f stamp (funcall fun dep-o dep-c))))
  stamp)

(defmethod compute-action-stamp (plan (o operation) (c component) &key just-done)
  ;; In a distant future, safe-file-write-date and component-operation-time
  ;; shall also be parametrized by the plan, or by a second model object.
  (let* ((stamp-lookup #'(lambda (o c) (aif (plan-action-status plan o c) (action-stamp it) t)))
         (out-files (output-files o c))
         (in-files (input-files o c))
         ;; Three kinds of actions:
         (out-op (and out-files t)) ; those that create files on the filesystem
         ;(image-op (and in-files (null out-files))) ; those that load stuff into the image
         ;(null-op (and (null out-files) (null in-files))) ; dependency placeholders that do nothing
         ;; When was the thing last actually done? (Now, or ask.)
         (op-time (or just-done (component-operation-time o c)))
         ;; Accumulated timestamp from dependencies (or T if forced or out-of-date)
         (dep-stamp (visit-dependencies plan o c stamp-lookup))
         ;; Time stamps from the files at hand, and whether any is missing
         (out-stamps (mapcar #'safe-file-write-date out-files))
         (in-stamps (mapcar #'safe-file-write-date in-files))
         (missing-in
           (loop :for f :in in-files :for s :in in-stamps :unless s :collect f))
         (missing-out
           (loop :for f :in out-files :for s :in out-stamps :unless s :collect f))
         (all-present (not (or missing-in missing-out)))
         ;; Has any input changed since we last generated the files?
         (earliest-out (stamps-earliest out-stamps))
         (latest-in (stamps-latest (cons dep-stamp in-stamps)))
         (up-to-date-p (stamp<= latest-in earliest-out))
         ;; If everything is up to date, the latest of inputs and outputs is our stamp
         (done-stamp (stamps-latest (cons latest-in out-stamps))))
    ;; Warn if some files are missing:
    ;; either our model is wrong or some other process is messing with our files.
    (when (and just-done (not all-present))
      (warn "~A completed without ~:[~*~;~*its input file~:p~2:*~{ ~S~}~*~]~
             ~:[~; or ~]~:[~*~;~*its output file~:p~2:*~{ ~S~}~*~]"
            (operation-description o c)
            missing-in (length missing-in) (and missing-in missing-out)
            missing-out (length missing-out)))
    ;; Note that we use stamp<= instead of stamp< to play nice with generated files.
    ;; Any race condition is intrinsic to the limited timestamp resolution.
    (if (or just-done ;; The done-stamp is valid: if we're just done, or
            ;; if all filesystem effects are up-to-date and there's no invalidating reason.
            (and all-present up-to-date-p (operation-done-p o c) (not (action-forced-p plan o c))))
        (values done-stamp ;; return the hard-earned timestamp
                (or just-done
                    (or out-op ;; a file-creating op is done when all files are up to date
                        ;; a image-effecting a placeholder op is done when it was actually run,
                        (and op-time (eql op-time done-stamp))))) ;; with the matching stamp
        ;; done-stamp invalid: return a timestamp in an indefinite future, action not done yet
        (values t nil))))


;;;; Generic support for plan-traversal

(defgeneric* plan-record-dependency (plan operation component))

(defgeneric call-while-visiting-action (plan operation component function)
  (:documentation "Detect circular dependencies"))

(defclass plan-traversal ()
  ((forced :initform nil :initarg :force :accessor plan-forced)
   (forced-not :initform nil :initarg :force-not :accessor plan-forced-not)
   (total-action-count :initform 0 :accessor plan-total-action-count)
   (planned-action-count :initform 0 :accessor plan-planned-action-count)
   (planned-output-action-count :initform 0 :accessor plan-planned-output-action-count)
   (visited-actions :initform (make-hash-table :test 'equal) :accessor plan-visited-actions)
   (visiting-action-set :initform (make-hash-table :test 'equal) :accessor plan-visiting-action-set)
   (visiting-action-list :initform () :accessor plan-visiting-action-list)))

(defmethod initialize-instance :after ((plan plan-traversal)
                                       &key (force () fp) (force-not () fnp) system &allow-other-keys)
  (with-slots (forced forced-not) plan
    (when fp (setf forced (normalize-forced-systems force system)))
    (when fnp (setf forced-not (normalize-forced-systems force-not system)))))

(defmethod (setf plan-action-status) (new-status (plan plan-traversal) (o operation) (c component))
  (setf (gethash (node-for o c) (plan-visited-actions plan)) new-status))

(defmethod plan-action-status ((plan plan-traversal) (o operation) (c component))
  (or (and (action-forced-not-p plan o c) (plan-action-status nil o c))
      (values (gethash (node-for o c) (plan-visited-actions plan)))))

(defmethod action-valid-p ((plan plan-traversal) (o operation) (s system))
  (and (not (action-forced-not-p plan o s)) (call-next-method)))

(defmethod call-while-visiting-action ((plan plan-traversal) operation component fun)
  (with-accessors ((action-set plan-visiting-action-set)
                   (action-list plan-visiting-action-list)) plan
    (let ((action (cons operation component)))
      (when (gethash action action-set)
        (error 'circular-dependency :actions
               (member action (reverse action-list) :test 'equal)))
      (setf (gethash action action-set) t)
      (push action action-list)
      (unwind-protect
           (funcall fun)
        (pop action-list)
        (setf (gethash action action-set) nil)))))


;;;; Actual traversal: traverse-action

(define-condition circular-dependency (system-definition-error)
  ((actions :initarg :actions :reader circular-dependency-actions))
  (:report (lambda (c s)
             (format s (compatfmt "~@<Circular dependency: ~3i~_~S~@:>")
                     (circular-dependency-actions c)))))

(defmacro while-visiting-action ((p o c) &body body)
  `(call-while-visiting-action ,p ,o ,c #'(lambda () ,@body)))

(defgeneric* traverse-action (plan operation component needed-in-image-p))

(defmethod traverse-action (plan operation component needed-in-image-p)
  (block nil
    (unless (action-valid-p plan operation component) (return nil))
    (plan-record-dependency plan operation component)
    (let* ((aniip (needed-in-image-p operation component))
           (eniip (and aniip needed-in-image-p))
           (status (plan-action-status plan operation component)))
      (when (and status (or (action-done-p status) (action-planned-p status) (not eniip)))
        ;; Already visited with sufficient need-in-image level: just return the stamp.
        (return (action-stamp status)))
      (labels ((visit-action (niip)
                 (visit-dependencies plan operation component
                                     #'(lambda (o c) (traverse-action plan o c niip)))
                 (multiple-value-bind (stamp done-p)
                     (compute-action-stamp plan operation component)
                   (let ((add-to-plan-p (or (eql stamp t) (and niip (not done-p)))))
                     (cond
                       ((and add-to-plan-p (not niip)) ;; if we need to do it,
                        (visit-action t)) ;; then we need to do it in the image!
                       (t
                        (setf (plan-action-status plan operation component)
                              (make-instance
                               'planned-action-status
                               :stamp stamp
                               :done-p (and done-p (not add-to-plan-p))
                               :planned-p add-to-plan-p
                               :index (if status (action-index status) (incf (plan-total-action-count plan)))))
                        (when add-to-plan-p
                          (incf (plan-planned-action-count plan))
                          (unless aniip
                            (incf (plan-planned-output-action-count plan))))
                        stamp))))))
        (while-visiting-action (plan operation component) ; maintain context, handle circularity.
          (visit-action eniip))))))


;;;; Sequential plans (the default)

(defclass sequential-plan (plan-traversal)
  ((actions-r :initform nil :accessor plan-actions-r)))

(defmethod plan-record-dependency ((plan sequential-plan)
                                   (operation operation) (component component))
  (declare (ignorable plan operation component))
  (values))

(defmethod (setf plan-action-status) :after
    (new-status (p sequential-plan) (o operation) (c component))
  (when (action-planned-p new-status)
    (push (cons o c) (plan-actions-r p))))

(defun* traverse-sequentially (operation component &rest keys &key &allow-other-keys)
  (let ((plan (apply 'make-instance 'sequential-plan :system (component-system component) keys)))
    (traverse-action plan operation component t)
    (reverse (plan-actions-r plan))))


;;;; high-level interface: traverse, perform-plan, plan-operates-on-p

(defgeneric* traverse (operation component &key &allow-other-keys)
  (:documentation
"Generate and return a plan for performing OPERATION on COMPONENT.

The plan returned is a list of dotted-pairs. Each pair is the CONS
of ASDF operation object and a COMPONENT object. The pairs will be
processed in order by OPERATE."))
(defgeneric* perform-plan (plan &key))
(defgeneric* plan-operates-on-p (plan component))

(defmethod traverse ((o operation) (c component) &rest keys &key &allow-other-keys)
  (apply 'traverse-sequentially o c keys))

(defmethod perform-plan ((steps list) &key)
  (let ((*package* *package*)
        (*readtable* *readtable*))
    (with-compilation-unit ()
      (loop :for (op . component) :in steps :do
        (perform-with-restarts op component)))))

(defmethod plan-operates-on-p ((plan list) (component-path list))
  (find component-path (mapcar 'cdr plan)
        :test 'equal :key 'component-find-path))

