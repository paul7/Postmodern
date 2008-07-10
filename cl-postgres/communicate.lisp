(in-package :cl-postgres)

;; These are used to synthesize reader and writer names for integer
;; reading/writing functions when the amount of bytes and the
;; signedness is known. Both the macro that creates the functions and
;; some macros that use them create names this way.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun integer-reader-name (bytes signed)
    (intern (format nil "~a~a~a~a" #:read- (if signed "" "U") #:int bytes)))
  (defun integer-writer-name (bytes signed)
    (intern (format nil "~a~a~a~a" #:write- (if signed "" "U") #:int bytes))))

(defmacro integer-reader (bytes)
  "Create a function to read integers from a binary stream."
  (let ((bits (* bytes 8)))
    (labels ((return-form (signed)
               (if signed
                   `(if (logbitp ,(1- bits) result)
                        (dpb result (byte ,(1- bits) 0) -1)
                        result)
                   `result))
             (generate-reader (signed)
               `(defun ,(integer-reader-name bytes signed) (socket)
                  (declare (type stream socket)
                           #.*optimize*)
                  ,(if (= bytes 1)
                       `(let ((result (the fixnum (read-byte socket))))
                          (declare (type (unsigned-byte 8) result))
                          ,(return-form signed))
                       `(let ((result 0))
                          (declare (type (unsigned-byte ,bits) result))
                          ,@(loop :for byte :from (1- bytes) :downto 0
                                   :collect `(setf (ldb (byte 8 ,(* 8 byte)) result)
                                                   (the fixnum (read-byte socket))))
                          ,(return-form signed))))))
      `(progn
;; This causes weird errors on SBCL in some circumstances. Disabled for now.
;;         (declaim (inline ,(integer-reader-name bytes t)
;;                          ,(integer-reader-name bytes nil)))
         ,(generate-reader t)
         ,(generate-reader nil)))))

(defmacro integer-writer (bytes)
  "Create a function to write integers to a binary stream."
  (let ((bits (* 8 bytes)))
    `(progn
      (declaim (inline ,(integer-writer-name bytes t)
                       ,(integer-writer-name bytes nil)))
      (defun ,(integer-writer-name bytes nil) (socket value)
        (declare (type stream socket)
                 (type (unsigned-byte ,bits) value)
                 #.*optimize*)
        ,@(if (= bytes 1)
              `((write-byte value socket))
              (loop :for byte :from (1- bytes) :downto 0
                    :collect `(write-byte (ldb (byte 8 ,(* byte 8)) value)
                               socket)))
        (values))
      (defun ,(integer-writer-name bytes t) (socket value)
        (declare (type stream socket)
                 (type (signed-byte ,bits) value)
                 #.*optimize*)
        ,@(if (= bytes 1)
              `((write-byte (ldb (byte 8 0) value) socket))
              (loop :for byte :from (1- bytes) :downto 0
                    :collect `(write-byte (ldb (byte 8 ,(* byte 8)) value)
                               socket)))
        (values)))))

;; All the instances of the above that we need.

(integer-reader 1)
(integer-reader 2)
(integer-reader 4)
(integer-reader 8)

(integer-writer 1)
(integer-writer 2)
(integer-writer 4)

(defun write-bytes (socket bytes)
  "Write a byte-array to a stream."
  (declare (type stream socket)
           (type (simple-array (unsigned-byte 8)) bytes)
           #.*optimize*)
  (write-sequence bytes socket))

(defun write-str (socket string)
  "Write a null-terminated string to a stream \(encoding it when UTF-8
support is enabled.)."
  (declare (type stream socket)
           (type string string)
           #.*optimize*)
  (enc-write-string string socket)
  (write-uint1 socket 0))

(defun read-bytes (socket length)
  "Read a byte array of the given length from a stream."
  (declare (type stream socket)
           (type fixnum length)
           #.*optimize*)
  (let ((result (make-array length :element-type '(unsigned-byte 8))))
    (read-sequence result socket)
    result))

(defun read-str (socket)
  "Read a null-terminated string from a stream. Takes care of encoding
when UTF-8 support is enabled."
  (declare (type stream socket)
           #.*optimize*)
  (enc-read-string socket :null-terminated t))

(defun skip-bytes (socket length)
  "Skip a given number of bytes in a binary stream."
  (declare (type stream socket)
           (type (unsigned-byte 32) length)
           #.*optimize*)
  (dotimes (i length)
    (read-byte socket)))

(defun skip-str (socket)
  "Skip a null-terminated string."
  (declare (type stream socket)
           #.*optimize*)
  (loop :for char :of-type fixnum = (read-byte socket)
        :until (zerop char)))

(defun ensure-socket-is-closed (socket &key abort)
  (when (open-stream-p socket)
    (handler-case
        (close socket :abort abort)
      (error (error)
        (warn "Ignoring the error which happened while trying to close PostgreSQL socket: ~A" error)))))
