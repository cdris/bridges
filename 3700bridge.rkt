#lang racket
(require (file "unix-socket/unix-socket-lib/racket/unix-socket.rkt"))
(require json)
(define start (current-milliseconds))

(define (now start) (- (current-milliseconds) start))

;; Parses the commandline arguments into two values, the bridge id
;; and a list of the lan ids
(define (parse-args vec)
  (match vec
    [(vector id lan ...) (values (string->symbol id) lan)]
    [(vector) (error 'no-command-args-read)]))

;; Pads a lan name to 108 bytes
(define (pad lan)
  (let* ([chars (cons #\nul (string->list lan))]
         [len (length chars)])
    (if (< len 108)
        (list->bytes (map char->integer
                          (append chars(build-list (- 108 len)
                                                   (λ (x) #\nul)))))
        (list->bytes (map char->integer chars)))))

;; Returns a list of input an output ports to all given lans
(define (lans->ports lans)
  (define i -1)
  (foldl (λ (x y) (begin (set! i (add1 i))
                         (hash-set y i x)))
         (hash)
         (map (λ (x) (call-with-values (λ () (unix-socket-connect (pad x))) cons)) lans)))
       

;; Broadcasts a bpdu to all given ports
(define (bpdu bridge-id root-id cost-to-root lans)
  (for ([lan (hash-values lans)])
    (broadcast bridge-id "ffff" "bpdu"
               (jsexpr->string (hash 'id bridge-id 'root root-id 'cost cost-to-root))
               (cadr lan))))

;; Broadcasts a message to the given port, formatted as a JSON message
(define (broadcast source destination type message port)
  (write-json (hash 'source source 'destination destination
                    'type type 'message message)
              port))

;; Parses an incoming message from a port
(define (read-message port)
  (let ([jsexpr (read-json port)])
    (if (eof-object? jsexpr) (values #f #f #f #f)
        (values (hash-ref jsexpr 'source)
                (hash-ref jsexpr 'destination)
                (hash-ref jsexpr 'type)
                (hash-ref jsexpr 'message))))) 

;; Handles a bpdu message
(define (handle-bpdu bridge-id root-id root-port cost-to-root des-bridge msg-port message lans)
  (let*-values ([(msg-bridge-id msg-root-id msg-cost) (values (hash-ref message 'id)
                                                              (hash-ref message 'root)
                                                              (hash-ref message 'cost))]
                [(msg-cost+1) (add1 msg-cost)])
    (if (or (< msg-root-id root-id)
            (and (not (or (> msg-root-id root-id) (> msg-cost+1 cost-to-root)))
                 (or (< msg-cost+1 cost-to-root)
                     (< msg-bridge-id des-bridge))))
        (begin (unless (= root-id msg-root-id)
                 (printf "New root: ~a/~a\n" bridge-id msg-root-id))
               (unless (= root-port msg-port)
                 (printf "Root port: ~a/~a\n" bridge-id msg-port))
          (bpdu bridge-id msg-root-id msg-cost+1 lans)
               (values msg-root-id msg-port msg-cost+1 msg-bridge-id))
        (values root-id root-port cost-to-root des-bridge))))

;; Handles a data message
(define (handle-data source destination type message msg-port fft open-lan-ids lans)
  (let ([port-age (hash-ref fft destination (λ () #f))]
        [msg-id (hash-ref message 'id)])
          ; we got the message on the port we'd send it out on
    (cond [(and port-age (= (car port-age) msg-port))
           (begin (printf "Not forwarding message ~a\n" msg-id)
                  fft)]
          ; we got the message and we'd send it out on an open port
          [(and port-age (member (car port-age) open-lan-ids))
           (begin (printf "Forwarding message ~a to port ~a\n" msg-id (car port-age))
                  (broadcast source destination type message
                             (cadr (hash-ref lans (car port-age)))))]
          ; otherwise broadcast to everyone
          [else
           (begin (printf "Broadcasting message ~a to all ports\n" msg-id)
                  (for ([open-port open-lan-ids]
                        #:unless (= open-port msg-port))
                    (broadcast source destination type message
                               (cadr (hash-ref lans open-port)))))])))

;; Updates the FFT with new information about the incoming message
(define (update-fft fft source msg-port)
  (hash-set source (cons msg-port (current-milliseconds))))
                    
;; Filters timed-out entries out of the fft
(define (scrub-fft fft)
  (let ([current (current-milliseconds)])
    (foldl (λ (x y) (hash-set y (car x) (cdr x))) (hash)
           (filter (λ (x) (< (- current (cddr x)) 5000)) (hash->list fft)))))

(define (main)
  (define-values (bridge-id lans) (parse-args (current-command-line-arguments)))
  (set! lans (lans->ports lans))
  (define-values (root-id root-port cost-to-root designated-bridge)
    (values bridge-id -1 0 bridge-id))
  (define-values (most-recent-bpdu fft open-lan-ids)
    (values (current-milliseconds) (hash) (hash-keys lans)))
  ; fft : address, port id, age
  (printf "Bridge ~a starting up\n" bridge-id)
  (letrec ([loop
         (λ ()
           (unless (< (now most-recent-bpdu) 500)
               (begin (set! most-recent-bpdu (current-milliseconds))
                      (bpdu bridge-id root-id cost-to-root lans)))
           (set! fft (scrub-fft fft))
           (for ([lan (hash->list lans)])
             (let-values ([(source destination type message) (read-message (cadr lan))])
               (when (or source destination type message)
                   (cond [(string=? type "bpdu")
                          (set!-values (root-id root-port cost-to-root designated-bridge)
                                       (handle-bpdu bridge-id root-id root-port cost-to-root
                                                    designated-bridge (car lan) message lans))]
                         [(string=? type "data")
                          (when (member (car lan) open-lan-ids)
                            (begin (update-fft source (car lan))
                                   (handle-data source destination type message (car lan)
                                                fft open-lan-ids lans)))]
                         [else (error 'invalid-message-type)]))))
           (loop))])
    (loop)))
                          
(main)
