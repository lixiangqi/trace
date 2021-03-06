(module annotator scheme/base

  (require (prefix-in kernel: syntax/kerncase)
           gui-debugger/marks
           "trace-util.rkt"
           mzlib/etc
           (prefix-in srfi: srfi/1/search)
           (for-syntax scheme/base)
           (only-in mzscheme [apply plain-apply])
           racket/list)
  (provide annotate-stx annotate-for-single-stepping)
 
  (define (arglist-bindings arglist-stx)
    (syntax-case arglist-stx ()
      [var
       (identifier? arglist-stx)
       (list arglist-stx)]
      [(var ...)
       (syntax->list arglist-stx)]
      [(var . others)
       (cons #'var (arglist-bindings #'others))]))

  ;; Retreives the binding of a variable from a normal-breakpoint-info.
  ;; Returns a list of pairs `(,variable-name-stx ,variable-value). Each
  ;; item in the list is a shadowed instance of a variable with the given
  ;; name, with the first item being the one in scope.
  #;
  (define (bindings top-mark marks sym)
    (let ([mark-list (cons top-mark (continuation-mark-set->list marks debug-key))])
      (map (lambda (binding) (list (mark-binding-binding binding)
                                   (mark-binding-value binding)))
           (lookup-all-bindings (lambda (id) (eq? (syntax-e id) sym))
                                mark-list))))


  ;; annotate-for-single-stepping uses annotate-stx to create an annotated
  ;; version of STX that pauses before and after each expression, in the style
  ;; of a single stepping debugger.  
  ;; 
  ;; BREAK?, BREAK-BEFORE, BREAK-AFTER are inserted into the resulting syntax
  ;; as 3D code.  When the resulting syntax is evaluated, before each
  ;; expression is evaluated, BREAK? is called with the syntax position of
  ;; that expression.  If BREAK? returns true, BREAK-BEFORE is called with two
  ;; arguments: the debug-info structure representing the first stack frame
  ;; and the current continuation marks representing the other stack frames
  ;; (use the key DEBUG-KEY).  If BREAK-BEFORE returns some value, the
  ;; evaluation skips the expression entirely and just returns that value.
  ;; Otherwise, evaluation proceeds normally.  After the expression is
  ;; evaluated, BREAK? is called with the position of the end of the expression.
  ;; If it returns true, BREAK-AFTER is called; otherwise, the expression returns
  ;; normally.  If BREAK-AFTER returns some value, the
  ;; return value of the expression is replaced by that value.
  ;;
  ;; RECORD-BOUND-ID and RECORD-TOP-LEVEL-ID are simply passed to ANNOTATE-STX.  
  
  (define annotate-for-single-stepping
    (opt-lambda (stx break? break-before break-after record-bound-id record-top-level-id record-log stx-table [source #f])
      (annotate-stx
       stx
       (lambda (debug-info annotated raw is-tail?)
         (let* ([start (syntax-position raw)]
                [end (+ start (syntax-span raw) -1)]
                [break? (break? (syntax-source raw))])
           (if is-tail?
               #`(let-values ([(value-list) #f])
                   (if (#%plain-app #,break? #,start)
                       (set! value-list (#%plain-app
                                         #,break-before
                                         #,debug-info
                                         (#%plain-app current-continuation-marks)))
                       (#%plain-app void))
                   (if (#%plain-app not value-list)
                       #,annotated
                       (#%plain-app plain-apply values value-list)))
               #`(let-values ([(value-list) #f])
                   (if (#%plain-app #,break? #,start)
                       (set! value-list (#%plain-app 
                                         #,break-before
                                         #,debug-info
                                         (#%plain-app current-continuation-marks)))
                       (#%plain-app void))
                   (if (#%plain-app not value-list)
                       (#%plain-app 
                        call-with-values
                        (#%plain-lambda () #,annotated)
                        (case-lambda
                          [(val) (if (#%plain-app #,break? #,end)
                                     (#%plain-app 
                                      #,break-after
                                      #,debug-info
                                      (#%plain-app current-continuation-marks) val)
                                     val)]
                          [vals (if (#%plain-app 
                                     #,break? #,end)
                                    (#%plain-app 
                                     plain-apply 
                                     #,break-after
                                     #,debug-info
                                     (#%plain-app current-continuation-marks) vals)
                                    (#%plain-app plain-apply values vals))]))
                       (if (#%plain-app #,break? #,end)
                           (#%plain-app 
                            plain-apply #,break-after
                            #,debug-info
                            (#%plain-app current-continuation-marks) 
                            value-list)
                           (#%plain-app plain-apply values value-list)))))))
       record-bound-id
       record-top-level-id
       record-log
       stx-table
       source)))


  ; annotate-stx : (syntax? 
  ;                 (mark? syntax? syntax? boolean? . -> . syntax?)
  ;                 (symbol? syntax? syntax? . -> . void?)
  ;                 . -> .  
  ;                 syntax?)


  ;; annotate-stx consumes a syntax, transverses it, and gives the opportunity
  ;; to the break-wrap to annotate every expression.  Once for each expression
  ;; in the source program, annotate-stx will call break-wrap with that
  ;; expression as an argument and insert the result in the original syntax.
  ;; Expressions that were duplicated during the macro expansion are
  ;; nevertheless only wrapped once.  
  ;;
  ;; annotate-stx inserts annotations around each expression that introduces a
  ;; new scope: let, lambda, and function calls.  These annotations reify the
  ;; call stack, and allows to list the current variable in scope, look up
  ;; their value, as well as change their value.  The reified stack is accessed
  ;; via the CURRENT-CONTINUATION-MARKS using the key DEBUG-KEY
  ;;
  ;; BREAK-WRAP is called with four arguments: 
  ;;   debug-info : the top frame of the reified stack (which never changes
  ;;   across execution)
  ;;   annotate-stx : the syntax with its subbranches already
  ;;   annotated. BREAK-WRAP should return a modified version of this syntax.  
  ;;   original-stx : the original syntax before annoatations 
  ;;   is-tail? : true when original syntax was in tail position
  ;;
  ;; The RECORD-BOUND-ID function is a callback that is invoked each time a
  ;; new variable is introduced, looked up, or set in STX (lexically).
  ;; RECORD-BOUND-ID takes three arguments: 
  ;;   use-case : either 'bind or 'ref or 'set, respectively
  ;;   bound-stx : syntax where the symbol is introduced, looked up, set, respectively 
  ;;   binding-stx : syntax where the symbol was bound
  ;;
  ;; Naturally, when USE-CASE is 'bind, BOUND-STX and BINDING-STX are equal.  
  ;;
  (define annotate-stx
    (opt-lambda (stx break-wrap record-bound-id record-top-level-id record-log stx-table [source #f])
      
      (define breakpoints (make-hasheq))
      
      (define argtable (make-hasheq))
      
      (define definitions (make-hasheq))
      
      (define (lookup-stx-table stx)
        (hash-ref stx-table (syntax-position stx) (lambda () stx)))
      
      (define (previous-bindings bound-vars)
        (if (null? bound-vars)
            #'null
            #'(#%plain-app debugger-local-bindings)))
      
      (define (top-level-annotate stx)
        (kernel:kernel-syntax-case/phase
         stx (namespace-base-phase)
         [(module identifier name mb)
          (module-annotate stx)]
         [else-stx
          (general-top-level-expr-iterator stx  #f)]))

      (define (module-annotate stx)
        (syntax-case stx ()
          [(_ identifier name mb)
           (syntax-case (disarm #'mb) ()
             [(plain-module-begin . module-level-exprs)
              (with-syntax ([(module . _) stx])
                (quasisyntax/loc stx (module identifier name
                                       #,(rearm
                                          #'mb
                                          #`(plain-module-begin
                                             (#%require (only racket/base))
                                             #,@(map (lambda (e) (module-level-expr-iterator
                                                                  e (list (syntax-e #'identifier)
                                                                          (syntax-source #'identifier))))
                                                     (syntax->list #'module-level-exprs)))))))])]))
      
      (define (module-level-expr-iterator stx module-name )
        (kernel:kernel-syntax-case
         stx #f
         [(#%provide . provide-specs)
          stx]
         [else-stx
          (general-top-level-expr-iterator stx module-name )]))
      
      (define (general-top-level-expr-iterator stx module-name )
        (kernel:kernel-syntax-case
         stx #f
         [(define-values (var ...) expr)
          (let ([def-stx (lookup-stx-table stx)])
            (hash-set! definitions (syntax-e (first (syntax->list #'(var ...)))) (quasisyntax/loc stx #,def-stx)))
          (quasisyntax/loc stx
            (define-values (var ...) #,(annotate #`expr '() #t module-name #f)))]
         [(define-syntaxes (var ...) expr)
          stx]
         [(begin-for-syntax . exprs)
          ;; compile time, so treat it like define-syntaxes
          stx]
         [(begin . top-level-exprs)
          (quasisyntax/loc stx (begin #,@(map (lambda (expr)
                                                (module-level-expr-iterator expr module-name ))
                                              (syntax->list #'top-level-exprs))))]
         [(#%require . require-specs)
          stx]
         [(module . _)
          ;; a submodule:
          (module-annotate stx)]
         [(module* . _)
          ;; a submodule:
          (module-annotate stx)]
         [else
          (annotate stx '() #f module-name #f)]))
      
      (define (annotate expr bound-vars is-tail? module-name lambda?)
        
        (define annotate-break?
          (let ([pos (syntax-position expr)]
                [src (syntax-source expr)])
            (and src pos
                 (hash-ref breakpoints pos (lambda () #t))
                 (kernel:kernel-syntax-case
                  expr #f
                  [(if test then else) #t]
                  [(begin . bodies) #t]
                  [(begin0 . bodies) #t]
                  [(let-values . clause) #t]
                  [(letrec-values . clause) #t]
                  [(set! var val) #t]
                  [(with-continuation-mark key mark body) #t]
                  [(#%plain-app . exprs) #t]
                  [_ #f])
                 (begin
                   (hash-set! breakpoints pos #f)
                   (when (not is-tail?)
                     (hash-set! breakpoints (+ pos (syntax-span expr) -1) #f))
                   #t))))
        
        (define (let/rec-values-annotator letrec?)
          (kernel:kernel-syntax-case
           (disarm expr) #f
           [(label (((var ...) rhs) ...) . bodies)
            (let* ([new-bindings (apply append
                                        (map syntax->list
                                             (syntax->list #`((var ...) ...))))]
                   [all-bindings (append new-bindings bound-vars)]
                   [new-rhs (map (lambda (expr)
                                   (annotate expr 
                                             (if letrec? all-bindings bound-vars)
                                             #f module-name lambda?))
                                 (syntax->list #'(rhs ...)))]
                   [last-body (car (reverse (syntax->list #'bodies)))]
                   [all-but-last-body (reverse (cdr (reverse (syntax->list #'bodies))))]
                   [bodies (append (map (lambda (expr)
                                          (annotate expr all-bindings #f module-name lambda?))
                                        all-but-last-body)
                                   (list (annotate
                                          last-body
                                          all-bindings 
                                          is-tail? module-name lambda?)))]
                   [local-debug-info (assemble-debug-info new-bindings new-bindings 'normal #f)]
                   [previous-bindings (previous-bindings bound-vars)])
              (for-each (lambda (id) (record-bound-id 'bind id id)) new-bindings)
              (with-syntax ([(new-rhs/trans ...) new-rhs]
                            [previous-bindings previous-bindings])
                (if letrec?
                    (quasisyntax/loc expr
                      (let ([old-bindings previous-bindings])
                        (label (((debugger-local-bindings) (#%plain-lambda ()
                                                             (#%plain-app
                                                              list*
                                                              #,@local-debug-info
                                                              old-bindings)))
                                ((var ...) new-rhs/trans) ...)
                               #,@bodies)))
                    (quasisyntax/loc expr
                      (label (((var ...) new-rhs/trans) ...)
                             (let ([debugger-local-bindings (#%plain-lambda ()
                                                              (#%plain-app
                                                               list*
                                                               #,@local-debug-info
                                                               previous-bindings))])
                               #,@bodies))))))]))
        
        (define (lambda-clause-annotator clause)
          (kernel:kernel-syntax-case
           clause #f
           [(arg-list . bodies)
            (let* ([new-bound-vars (arglist-bindings #'arg-list)]
                   [all-bound-vars (append new-bound-vars bound-vars)]
                   [new-bodies (let loop ([bodies (syntax->list #'bodies)])
                                 (if (equal? '() (cdr bodies))
                                     (list (annotate (car bodies) all-bound-vars #t module-name #t))
                                     (cons (annotate (car bodies) all-bound-vars #f module-name #t)
                                           (loop (cdr bodies)))))]
                   [debug-info-stx (assemble-debug-info new-bound-vars new-bound-vars 'normal #f)]
                   [function-stx (lookup-stx-table clause)]
                   [arg-stxes (map (lambda (a) (lookup-stx-table a)) new-bound-vars)]
                   [args (lambda () arg-stxes)])
              (hash-set! argtable (syntax-position function-stx) arg-stxes)
              (quasisyntax/loc clause
                (arg-list
                 (let ([arg-values (map (lambda (x)
                                          (if (#,traced-value? (x))
                                              (#,traced-value-val (x))
                                              x))
                                        (list #,@debug-info-stx))]
                       [captured (continuation-mark-set-first #f 'stack null)]
                       [var-table (make-hasheq)])
                   (unless (empty? '#,new-bound-vars)
                       (for-each (lambda (stx val) (hash-ref! var-table stx val)) (#,args) (list #,@debug-info-stx)))
                   (let ([stack-info (list (quote-syntax #,function-stx) (#%plain-lambda () var-table))])
                   (with-continuation-mark 'stack (append captured (list stack-info))
                     (with-continuation-mark 'inspect (list (quote-syntax #,function-stx) arg-values)
                       (begin
                         #,@new-bodies))))))))]))

        (define annotated
          (rearm
           expr
           (kernel:kernel-syntax-case
            (disarm expr) #f
            [var-stx 
             (identifier? #'var-stx)
             expr]
            [(#%plain-lambda . clause)
             (quasisyntax/loc expr 
               (#%plain-lambda #,@(lambda-clause-annotator #'clause)))]
            
            [(if test then else)
             (quasisyntax/loc expr 
               (let* ([new-test #,(annotate #'test bound-vars #f module-name lambda?)]
                      [test-val (if (#,traced-value? new-test)
                                    (#,traced-value-val new-test)
                                    new-test)])
                 (if test-val
                     #,(annotate #'then bound-vars is-tail? module-name lambda?)
                     #,(annotate #'else bound-vars is-tail? module-name lambda?))))]
            
            [(begin . bodies)
             (letrec ([traverse
                       (lambda (lst)
                         (if (and (pair? lst) (equal? '() (cdr lst)))
                             `(,(annotate (car lst) bound-vars is-tail? module-name lambda?))
                             (cons (annotate (car lst) bound-vars #f module-name lambda?)
                                   (traverse (cdr lst)))))])
               (quasisyntax/loc expr (begin #,@(traverse (syntax->list #'bodies)))))]
            
            [(quote datum)
             (quasisyntax/loc expr (#,traced-value datum (#,dtree 'lf datum #f)))]
            
            [(#%plain-app . exprs)
             (let* ([params (map (lambda (exp)
                                  (annotate exp bound-vars #f module-name lambda?))
                                (rest (syntax->list #'exprs)))]
                    [stx-property (syntax-property expr 'inspect)]
                    [op (first (syntax->list #'exprs))]
                    [op-name (syntax-e (first (syntax->list #'exprs)))]
                    [raw-expr (lookup-stx-table #'exprs)]
                    [raw-op (lookup-stx-table op)])
               (cond 
                 [stx-property
                  (with-syntax ([to-inspect (third (syntax->list expr))]
                                [op (first (syntax->list #'exprs))])
                    (quasisyntax/loc expr
                      (let ([to-inspect-stx (#,lookup-stx-table #'to-inspect)])
                        (#%plain-app #,record-log to-inspect-stx
                                     #,@params
                                     #f #f #f (current-continuation-marks) #f))))]
                 [else
                  (with-syntax ([op op]
                                [raw-op raw-op]
                                [raw-expr raw-expr])
                    (quasisyntax/loc expr
                      (let ([ns (variable-reference->namespace (#%variable-reference))]
                            [op-name (syntax-e #'op)])
                        (if (namespace-variable-value op-name #f (lambda () #f) ns)
                            ; self-defined function 
                            (#,ap (#,traced-value op (#,dtree 'lff op-name #f)) #'raw-op #,@params)
                            ; do not need to keep track of the library functions; no traced form
                            (#,ap op #'raw-expr #,@params)))))]))]
            
            [else (error 'expr-syntax-object-iterator "unknown expr: ~a"
                         (syntax->datum expr))])))
        annotated)
      
      (values (top-level-annotate stx) (hash-map breakpoints (lambda (k v) k)) argtable definitions)))

  (define (disarm stx) (syntax-disarm stx code-insp))
  (define (rearm old new) (syntax-rearm new old))

  (define code-insp (variable-reference->module-declaration-inspector
                     (#%variable-reference))))
