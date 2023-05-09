(cl:in-package #:eclector.reader.test)

(def-suite* :eclector.reader.labeled-objects
  :in :eclector.reader)

;;; Count fixup calls
;;;
;;; Avoiding unnecessary traversal of read objects and unnecessary
;;; `fixup' calls is an important aspect of the labeled objects
;;; sub-system. The following client helps ensuring that no
;;; unnecessary `fixup' calls are made.

(defclass call-counting-client ()
  ((%fixup-graph-count :accessor fixup-graph-count
                       :initform 0)
   (%fixup-count :accessor fixup-count
                 :initform 0)))

(defmethod eclector.reader:fixup-graph :after ((client call-counting-client)
                                               labeled-object
                                               &key object-key)
  (declare (ignore labeled-object object-key))
  (incf (fixup-graph-count client)))

(defmethod eclector.reader:fixup :after ((client call-counting-client)
                                         object
                                         seen-objects)
  (declare (ignore object seen-objects))
  (incf (fixup-count client)))

;;; Tests

(defclass mock-object ()
  ((%a :initarg :a :reader a)
   (%b :initarg :b :reader b)))

(test fixup/smoke
  "Smoke test for the FIXUP generic function."
  (mapc (lambda (object-expected)
          (destructuring-bind (object expected fixup-count) object-expected
            (let ((client (make-instance 'call-counting-client))
                  (seen (make-hash-table :test #'eq)))
              (eclector.reader:fixup client object seen)
              (typecase object
                (mock-object
                 (let ((slot-values (list (if (slot-boundp object '%a)
                                              (a object)
                                              'unbound)
                                          (b object))))
                   (is (equalp expected slot-values))))
                (hash-table
                 (let ((alist (alexandria:hash-table-alist object)))
                   (is (alexandria:set-equal expected alist :test #'equal)
                       "~@<Expected hash table entries ~S but got ~S. ~
                        Mismatches: ~S and ~S~@:>"
                       expected alist
                       (set-difference expected alist :test #'equal)
                       (set-difference alist expected :test #'equal))))
                (t
                 (is (equalp expected object))))
              (is (= fixup-count (fixup-count client))
                  "~@<For object, ~S expected ~A to be called ~D time~:P, ~
                   but it was called ~D time~:P~@:>"
                  object 'eclector.reader:fixup
                  fixup-count (fixup-count client)))))
        (flet ((labeled-object (object &optional (label 1) (finalp t))
                 (eclector.reader:call-with-label-tracking
                  nil (lambda ()
                        (let ((labeled-object (eclector.reader:note-labeled-object
                                               nil nil label nil)))
                          (if finalp
                              (eclector.reader:finalize-labeled-object
                               nil labeled-object object)
                              labeled-object))))))
          (list ;; cons
                (let* ((a (gensym))
                       (marker (labeled-object a)))
                  (list (list 1 marker a (cons 2 marker))
                        (list 1 a      a (cons 2 a))
                        9))
                ;; vector
                (let* ((a (gensym))
                       (marker (labeled-object a)))
                  (list (vector a marker)
                        (vector a a)
                        2))
                ;; Specialized arrays (smoke test since nothing has to be fixed up)
                (list "foo" "foo" 1)
                #.(if (subtypep (upgraded-array-element-type '(unsigned-byte 8))
                                'number)
                      '(list (make-array 2 :element-type     '(unsigned-byte 8)
                                           :initial-contents '(1 2))
                             (make-array 2 :element-type     '(unsigned-byte 8)
                                           :initial-contents '(1 2))
                             1)
                      '(list nil nil 1))
                ;; standard-object
                (let* ((a (gensym))
                       (marker (labeled-object a)))
                  (list (make-instance 'mock-object :a a :b marker)
                        (list a a)
                        2))
                ;; standard-object with unbound slot
                (let* ((a (gensym))
                       (marker (labeled-object a)))
                  (list (make-instance 'mock-object :b marker)
                        (list 'unbound a)
                        1))
                ;; hash-table
                (let* ((a (gensym))
                       (b (gensym))
                       (c (gensym))
                       (d (gensym))
                       (e (gensym))
                       (f (gensym))
                       (g (gensym))
                       (marker1 (labeled-object a 1))
                       (marker2 (labeled-object b 2))
                       (marker3 (labeled-object c 3))
                       (marker4 (labeled-object d 4))
                       (marker5 (labeled-object e 5))
                       ;; The following two labeled objects are not
                       ;; finalized and should remain untouched.
                       (marker6 (labeled-object f 6 nil))
                       (marker7 (labeled-object g 7 nil)))
                  (list (alexandria:alist-hash-table
                         (list (cons (cons a marker2) 1) (cons 2 a) (cons 3 marker1)
                               (cons b 4) (cons 5 marker2) (cons 6 b)
                               (cons 7 (cons 8 marker3))
                               (cons marker4 9) (cons marker5 marker4)
                               (cons marker6 (cons 10 marker2)) (cons 11 marker7)))
                        (list (cons (cons a b) 1) (cons 2 a) (cons 3 a)
                              (cons b 4) (cons 5 b) (cons 6 b)
                              (cons 7 (cons 8 c))
                              (cons d 9) (cons e d)
                              (cons marker6 (cons 10 b)) (cons 11 marker7))
                        17))))))

(test fixup/call-count
  "Ensure absence of redundant `fixup' calls."
  (do-stream-input-cases (() expected-fixup-graph-count expected-fixup-count)
    (let* ((client (make-instance 'call-counting-client))
           (result (with-stream (stream)
                     (let ((eclector.base:*client* client))
                       (eclector.reader:read stream))))
           (expected (with-stream (stream)
                       (read stream))))
      (expect "read object "(equal* expected result))
      (expect "fixup graph call count"
              (= expected-fixup-graph-count (fixup-graph-count client)))
      (expect "fixup call count"
              (= expected-fixup-count (fixup-count client))))
    '(("(#1=(:a :b) #1#)"               0 0)
      ("#1=(#2=(:a #2# :b) :c #1# :d)"  1 12)
      ("(#1=(:a #2=(#3=(:b #3#))) #1#)" 1 4)
      ("(#1=(:a #1#) :b #2=(:b #2#))"   2 8))))

;;; Random test

(test labeled-objects/random
  "Random test for labeled objects."
  (let ((*test-dribble* (make-broadcast-stream)) ; too much output otherwise
        (*num-trials* 10000)
        (*max-trials* 10000))
    (for-all ((expression (gen-labels-and-references)))
      (let* ((input (let ((*print-circle* t))
                      (prin1-to-string expression)))
             (result (eclector.reader:read-from-string input)))
        (assert (equal* expression (read-from-string input)))
        (is (equal* expression result))))))
